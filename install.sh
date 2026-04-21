#!/bin/bash
set -euo pipefail

SA_DIR="$HOME/.local/share/sa"
mkdir -p "$SA_DIR"

# ── Write sa_daemon.py ────────────────────────────────────────────────────────

cat > "$SA_DIR/sa_daemon.py" << 'PYEOF'
#!/usr/bin/env python3
"""StealthAssist daemon — persistent background process.

Listens for SIGUSR1 (from hotkey trigger), captures screen via
ScreenCast portal (Wayland) or X11 fallback, queries Gemini API,
and shows a GTK3 overlay with the answer.

All D-Bus/GLib operations run on the MAIN thread so portal signals
are delivered correctly — this is the key fix for permission dialogs
and "no method" errors.
"""

import gi, os, sys, signal, json, base64, tempfile, threading, shutil, subprocess
import urllib.request, urllib.error

# ── GI version locks ─────────────────────────────────────────────────────────

gi.require_version('Gtk',      '3.0')
gi.require_version('Gdk',      '3.0')
gi.require_version('GdkPixbuf','2.0')
gi.require_version('GLib',     '2.0')
gi.require_version('Gio',      '2.0')

from gi.repository import Gtk, Gdk, GdkPixbuf, GLib, Gio

_HAS_GI_CAIRO = False
try:
    gi.require_foreign("cairo")
    import cairo
    _HAS_GI_CAIRO = True
except (ImportError, Exception):
    pass

_HAS_GST = False
try:
    gi.require_version('Gst', '1.0')
    from gi.repository import Gst
    Gst.init(None)
    _HAS_GST = True
except (ImportError, ValueError, Exception):
    pass

# ── Configuration ────────────────────────────────────────────────────────────

API_KEY = "AQ.Ab8RN6LCZNVoEuePOYV7Cg4S956XjUU5uabyw5UIwC49oshXww"
MODEL   = "gemini-2.5-flash"
PROMPT  = (
    "You are an expert assistant. Look at this screenshot carefully. "
    "Identify the question being asked and all answer options visible. "
    "Return ONLY the correct answer (e.g. 'A', 'B', 'C', 'D', or exact text). "
    "If free-form, answer in under 50 words. No explanation. Just the answer."
)

SA_DIR_PATH  = os.path.dirname(os.path.abspath(__file__))
TOKEN_FILE   = os.path.join(SA_DIR_PATH, '.restore_token')
PID_FILE     = os.path.join(SA_DIR_PATH, '.pid')

# ── D-Bus helpers (all run on main GLib thread) ──────────────────────────────

_bus = None
def _get_bus():
    global _bus
    if _bus is None:
        _bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    return _bus

def _sender_tag():
    return _get_bus().get_unique_name().replace('.', '_').replace(':', '')

def _portal_request(proxy, method, args_fn, timeout=15):
    """Call a portal method with pre-subscribed response signal.
    MUST be called from the main GLib thread."""
    import random, string
    bus   = _get_bus()
    token = 'sa_' + ''.join(random.choices(string.ascii_lowercase, k=8))
    path  = f"/org/freedesktop/portal/desktop/request/{_sender_tag()}/{token}"

    result_box = [None]
    loop = GLib.MainLoop(GLib.MainContext.default())

    def on_response(conn, sender, p, ifc, sig, params):
        result_box[0] = params.unpack()
        loop.quit()

    sid = bus.signal_subscribe(
        'org.freedesktop.portal.Desktop',
        'org.freedesktop.portal.Request', 'Response',
        path, None, Gio.DBusSignalFlags.NO_MATCH_RULE, on_response
    )

    try:
        proxy.call_sync(method, args_fn(token), Gio.DBusCallFlags.NONE, 5000, None)
        GLib.timeout_add(timeout * 1000, lambda: (loop.quit(), False)[1])
        loop.run()
    finally:
        bus.signal_unsubscribe(sid)

    return result_box[0]

# ── Restore token management ────────────────────────────────────────────────

def _load_restore_token():
    try:
        with open(TOKEN_FILE) as f:
            t = f.read().strip()
            return t if t else ''
    except Exception:
        return ''

def _save_restore_token(token):
    try:
        with open(TOKEN_FILE, 'w') as f:
            f.write(token)
    except Exception:
        pass

# ── Screen capture: ScreenCast portal (Wayland) ─────────────────────────────

def _capture_screencast(path):
    """ScreenCast portal capture. Uses persist_mode=2 + restore_token
    so permission dialog only appears on the very first invocation."""
    if not _HAS_GST:
        return False

    import random, string
    bus = _get_bus()
    restore_token = _load_restore_token()

    try:
        sc = Gio.DBusProxy.new_sync(
            bus, Gio.DBusProxyFlags.NONE, None,
            'org.freedesktop.portal.Desktop',
            '/org/freedesktop/portal/desktop',
            'org.freedesktop.portal.ScreenCast', None
        )

        # 1. CreateSession
        sess_tok = 'sa_s_' + ''.join(random.choices(string.ascii_lowercase, k=6))
        resp = _portal_request(sc, 'CreateSession',
            lambda tok: GLib.Variant('(a{sv})', ({
                'session_handle_token': GLib.Variant('s', sess_tok),
                'handle_token': GLib.Variant('s', tok),
            },)))
        if not resp or resp[0] != 0:
            return False
        session = resp[1]['session_handle']

        # 2. SelectSources (with persist + restore_token for stealth)
        src_opts = {
            'types':        GLib.Variant('u', 1),      # MONITOR
            'multiple':     GLib.Variant('b', False),
            'persist_mode': GLib.Variant('u', 2),       # persist until revoked
        }
        if restore_token:
            src_opts['restore_token'] = GLib.Variant('s', restore_token)

        resp = _portal_request(sc, 'SelectSources',
            lambda tok: GLib.Variant('(oa{sv})', (session, {
                **src_opts, 'handle_token': GLib.Variant('s', tok),
            })))
        if not resp or resp[0] != 0:
            return False

        # 3. Start — with valid restore_token this shows NO dialog
        resp = _portal_request(sc, 'Start',
            lambda tok: GLib.Variant('(osa{sv})', (session, '', {
                'handle_token': GLib.Variant('s', tok),
            })), timeout=30)
        if not resp or resp[0] != 0:
            if restore_token:
                _save_restore_token('')
            return False

        streams = resp[1].get('streams', [])
        if not streams:
            return False
        node_id = streams[0][0]

        # Save NEW restore_token (tokens are single-use, must rotate)
        new_token = resp[1].get('restore_token', '')
        if new_token:
            _save_restore_token(new_token)

        # 4. Get PipeWire FD
        fd_result = bus.call_with_unix_fd_list_sync(
            'org.freedesktop.portal.Desktop',
            '/org/freedesktop/portal/desktop',
            'org.freedesktop.portal.ScreenCast',
            'OpenPipeWireRemote',
            GLib.Variant('(oa{sv})', (session, {})),
            GLib.VariantType('(h)'),
            Gio.DBusCallFlags.NONE, 5000, None, None
        )
        pw_fd = fd_result[1].get(fd_result[0].unpack()[0])

        # 5. Capture single frame via GStreamer
        pipe = Gst.parse_launch(
            f'pipewiresrc fd={pw_fd} path={node_id} num-buffers=1 ! '
            f'videoconvert ! pngenc ! filesink location={path}'
        )
        try:
            pipe.set_state(Gst.State.PLAYING)
            gst_bus = pipe.get_bus()
            gst_bus.timed_pop_filtered(5 * Gst.SECOND,
                Gst.MessageType.EOS | Gst.MessageType.ERROR)
        finally:
            pipe.set_state(Gst.State.NULL)

        # 6. Close session
        try:
            bus.call_sync(
                'org.freedesktop.portal.Desktop', session,
                'org.freedesktop.portal.Session', 'Close',
                None, None, Gio.DBusCallFlags.NONE, 1000, None)
        except Exception:
            pass

        return os.path.exists(path) and os.path.getsize(path) > 0

    except Exception:
        return False


def _capture_x11(path):
    """Direct X11 root-window capture."""
    try:
        root = Gdk.get_default_root_window()
        if root is None:
            return False
        w, h = root.get_width(), root.get_height()
        pb = Gdk.pixbuf_get_from_window(root, 0, 0, w, h)
        if pb is None:
            return False
        pb.savev(path, 'png', [], [])
        return True
    except Exception:
        return False


def _capture_gnome_screenshot(path):
    if not shutil.which('gnome-screenshot'):
        return False
    try:
        subprocess.run(['gnome-screenshot', f'--file={path}'],
                       capture_output=True, timeout=10)
        return os.path.exists(path) and os.path.getsize(path) > 0
    except Exception:
        return False


def capture_screen(path):
    session = os.environ.get('XDG_SESSION_TYPE', 'x11').lower()

    if session != 'wayland':
        if _capture_x11(path):
            return

    if _capture_screencast(path):
        return

    if _capture_gnome_screenshot(path):
        return

    if _capture_x11(path):
        return

    raise RuntimeError("No screenshot method available")

# ── Image pre-processing ─────────────────────────────────────────────────────

def resize_image(path, max_dim=768):
    try:
        pb = GdkPixbuf.Pixbuf.new_from_file(path)
        w, h = pb.get_width(), pb.get_height()
        if max(w, h) > max_dim:
            s = max_dim / max(w, h)
            pb = pb.scale_simple(int(w*s), int(h*s), GdkPixbuf.InterpType.BILINEAR)
        pb.savev(path, 'png', [], [])
    except Exception:
        pass

# ── Gemini API ────────────────────────────────────────────────────────────────

def query_gemini(image_path):
    with open(image_path, 'rb') as f:
        b64 = base64.b64encode(f.read()).decode()
    url  = (f"https://generativelanguage.googleapis.com/v1beta/models"
            f"/{MODEL}:generateContent?key={API_KEY}")
    body = json.dumps({
        "contents": [{"parts": [
            {"text": PROMPT},
            {"inline_data": {"mime_type": "image/png", "data": b64}}
        ]}],
        "generationConfig": {
            "temperature": 0.05, "topK": 32,
            "topP": 0.85, "maxOutputTokens": 512
        }
    }).encode()

    def attempt():
        req = urllib.request.Request(url, data=body,
            headers={"Content-Type": "application/json"})
        resp = urllib.request.urlopen(req, timeout=15)
        data = json.loads(resp.read())
        parts = data['candidates'][0]['content']['parts']
        return "".join(p.get("text", "") for p in parts).strip()

    try:
        return attempt()
    except urllib.error.HTTPError as e:
        if e.code == 429:
            import time; time.sleep(4)
            try:    return attempt()
            except: return "Rate limited"
        return f"API error ({e.code})"
    except Exception as e:
        return f"Error: {e}"

# ── GTK3 Overlay ──────────────────────────────────────────────────────────────

class Overlay(Gtk.Window):
    def __init__(self, text):
        super().__init__()
        self.set_decorated(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_keep_above(True)
        self.set_resizable(False)

        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual:
            self.set_visual(visual)

        if _HAS_GI_CAIRO:
            self.set_app_paintable(True)
            self.connect('draw', self._on_draw)
        else:
            self.override_background_color(
                Gtk.StateFlags.NORMAL,
                Gdk.RGBA(red=0.0, green=0.0, blue=0.0, alpha=0.55))

        display = Gdk.Display.get_default()
        monitor = display.get_primary_monitor() or display.get_monitor(0)
        if monitor:
            g = monitor.get_geometry()
            self.set_size_request(240, -1)
            self.move(g.x + g.width - 260, g.y + g.height - 200)

        self._label = Gtk.Label(label=text)
        self._label.set_line_wrap(True)
        self._label.set_max_width_chars(30)
        self._label.set_halign(Gtk.Align.START)
        self._label.set_name("sa_label")

        css = b"""
        #sa_label {
            font-family: 'Ubuntu', 'Sans', sans-serif;
            font-size: 10pt;
            color: rgba(255, 255, 255, 0.85);
            text-shadow: 1px 1px 3px rgba(0, 0, 0, 0.95);
            padding: 8px 12px;
        }
        """
        prov = Gtk.CssProvider()
        prov.load_from_data(css)
        self._label.get_style_context().add_provider(
            prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.add(self._label)
        self.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
        self.connect('button-press-event', lambda *_: self._dismiss())

    def _on_draw(self, widget, cr):
        cr.set_source_rgba(0, 0, 0, 0.55)
        cr.set_operator(cairo.Operator.SOURCE)
        cr.paint()
        return False

    def set_text(self, text):
        self._label.set_text(text)
        self._label.queue_draw()

    def _dismiss(self):
        self.hide()
        self.destroy()

# ── Setup mode (first-time ScreenCast permission grant) ──────────────────────

def run_setup():
    """One-time ScreenCast permission grant. Saves restore_token."""
    if not _HAS_GST:
        return False

    import random, string
    bus = _get_bus()

    sc = Gio.DBusProxy.new_sync(
        bus, Gio.DBusProxyFlags.NONE, None,
        'org.freedesktop.portal.Desktop',
        '/org/freedesktop/portal/desktop',
        'org.freedesktop.portal.ScreenCast', None)

    sess_tok = 'sa_setup_' + ''.join(random.choices(string.ascii_lowercase, k=4))
    resp = _portal_request(sc, 'CreateSession',
        lambda tok: GLib.Variant('(a{sv})', ({
            'session_handle_token': GLib.Variant('s', sess_tok),
            'handle_token': GLib.Variant('s', tok),
        },)))
    if not resp or resp[0] != 0:
        return False
    session = resp[1]['session_handle']

    resp = _portal_request(sc, 'SelectSources',
        lambda tok: GLib.Variant('(oa{sv})', (session, {
            'types':        GLib.Variant('u', 1),
            'multiple':     GLib.Variant('b', False),
            'persist_mode': GLib.Variant('u', 2),
            'handle_token': GLib.Variant('s', tok),
        })))
    if not resp or resp[0] != 0:
        return False

    resp = _portal_request(sc, 'Start',
        lambda tok: GLib.Variant('(osa{sv})', (session, '', {
            'handle_token': GLib.Variant('s', tok),
        })), timeout=60)
    if not resp or resp[0] != 0:
        return False

    new_token = resp[1].get('restore_token', '')
    if new_token:
        _save_restore_token(new_token)

    try:
        bus.call_sync(
            'org.freedesktop.portal.Desktop', session,
            'org.freedesktop.portal.Session', 'Close',
            None, None, Gio.DBusCallFlags.NONE, 1000, None)
    except Exception:
        pass

    return bool(new_token)

# ── Daemon ────────────────────────────────────────────────────────────────────

class Daemon:
    """Persistent background daemon. Waits for SIGUSR1 to capture."""

    def __init__(self):
        self._overlay = None
        self._busy = False
        self._loop = GLib.MainLoop()

    def _write_pid(self):
        try:
            with open(PID_FILE, 'w') as f:
                f.write(str(os.getpid()))
        except Exception:
            pass

    def _remove_pid(self):
        try:
            os.unlink(PID_FILE)
        except OSError:
            pass

    def _on_trigger(self):
        """Called on main thread via GLib.idle_add when SIGUSR1 received."""
        if self._busy:
            return False

        # If overlay is showing, dismiss it
        if self._overlay is not None:
            try:
                self._overlay._dismiss()
            except Exception:
                pass
            self._overlay = None
            return False

        self._busy = True
        self._do_capture()
        return False

    def _do_capture(self):
        """Capture screen, query Gemini, show overlay. Runs on main thread."""
        tmp_fd, tmp_path = tempfile.mkstemp(suffix='.png', prefix='.sa_')
        os.close(tmp_fd)

        try:
            capture_screen(tmp_path)
            resize_image(tmp_path)
        except Exception as e:
            self._show_overlay(f"Capture error: {e}")
            try: os.unlink(tmp_path)
            except OSError: pass
            self._busy = False
            return

        # Query Gemini in a thread (pure HTTP, no GLib needed)
        def query_thread():
            try:
                answer = query_gemini(tmp_path)
            except Exception as e:
                answer = f"Error: {e}"
            finally:
                try: os.unlink(tmp_path)
                except OSError: pass
            GLib.idle_add(self._show_overlay, answer)

        threading.Thread(target=query_thread, daemon=True).start()

    def _show_overlay(self, text):
        """Show overlay on main thread."""
        self._overlay = Overlay(text)
        self._overlay.show_all()
        GLib.timeout_add_seconds(30, self._auto_dismiss)
        self._busy = False
        return False

    def _auto_dismiss(self):
        if self._overlay is not None:
            try:
                self._overlay._dismiss()
            except Exception:
                pass
            self._overlay = None
        return False

    def run(self):
        self._write_pid()

        # SIGUSR1 triggers capture via main loop
        def sig_handler(signum, frame):
            GLib.idle_add(self._on_trigger)

        signal.signal(signal.SIGUSR1, sig_handler)
        signal.signal(signal.SIGTERM, lambda *_: (self._remove_pid(), self._loop.quit()))

        try:
            self._loop.run()
        finally:
            self._remove_pid()

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--setup':
        ok = run_setup()
        sys.exit(0 if ok else 1)

    daemon = Daemon()
    daemon.run()

if __name__ == '__main__':
    main()
PYEOF

chmod +x "$SA_DIR/sa_daemon.py"

# ── Write trigger.sh ──────────────────────────────────────────────────────────

cat > "$SA_DIR/trigger.sh" << 'SHEOF'
#!/bin/bash
PID_FILE="$HOME/.local/share/sa/.pid"
DAEMON="$HOME/.local/share/sa/sa_daemon.py"

# Read stored PID
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null)
    # Check if daemon is actually running
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        # Send trigger signal
        kill -USR1 "$PID" 2>/dev/null
        exit 0
    fi
fi

# Daemon not running — start it
nohup bash -c "exec -a gvfsd-sys python3 \"$DAEMON\"" &>/dev/null &
DPID=$!

# Wait for daemon to be ready (up to 2 seconds)
for i in $(seq 1 20); do
    sleep 0.1
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            kill -USR1 "$PID" 2>/dev/null
            exit 0
        fi
    fi
done
SHEOF

chmod +x "$SA_DIR/trigger.sh"

# ── Remove old app.py if exists ───────────────────────────────────────────────

rm -f "$SA_DIR/app.py"

# ── Create autostart entry ────────────────────────────────────────────────────

AUTOSTART_DIR="$HOME/.config/autostart"
mkdir -p "$AUTOSTART_DIR"

cat > "$AUTOSTART_DIR/sa-daemon.desktop" << EOF
[Desktop Entry]
Type=Application
Name=System Helper
Exec=bash -c 'exec -a gvfsd-sys python3 "$SA_DIR/sa_daemon.py"'
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

# ── Register GNOME hotkey (Ctrl+Shift+;) ─────────────────────────────────────

register_hotkey() {
    command -v gsettings &>/dev/null || return 1
    local TRIGGER_PATH="$SA_DIR/trigger.sh"
    local SCHEMA="org.gnome.settings-daemon.plugins.media-keys"
    local BP="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/sa0/"

    gsettings set "${SCHEMA}.custom-keybinding:${BP}" name    'SA'              || return 1
    gsettings set "${SCHEMA}.custom-keybinding:${BP}" command "$TRIGGER_PATH"   || return 1
    gsettings set "${SCHEMA}.custom-keybinding:${BP}" binding '<Control><Shift>semicolon' || return 1

    local CUR
    CUR=$(gsettings get "$SCHEMA" custom-keybindings) || return 1
    if echo "$CUR" | grep -q 'sa0'; then
        :
    elif [ "$CUR" = "@as []" ]; then
        gsettings set "$SCHEMA" custom-keybindings "['$BP']"
    else
        gsettings set "$SCHEMA" custom-keybindings "${CUR%]},'$BP']"
    fi
    return 0
}
register_hotkey || true

# ── Kill any old instances ────────────────────────────────────────────────────

pkill -f 'gvfsd-sys' 2>/dev/null || true
sleep 0.5

# ── One-time ScreenCast permission grant (Wayland only) ──────────────────────

if [ "${XDG_SESSION_TYPE:-x11}" = "wayland" ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  A screen-sharing dialog will appear."
    echo "  Select your monitor and click Share."
    echo "  This is a ONE-TIME setup — never shown again."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    python3 "$SA_DIR/sa_daemon.py" --setup && SETUP_OK=true || SETUP_OK=false
else
    SETUP_OK=true
fi

# ── Start the daemon ─────────────────────────────────────────────────────────

nohup bash -c "exec -a gvfsd-sys python3 \"$SA_DIR/sa_daemon.py\"" &>/dev/null &

# ── Notify user ───────────────────────────────────────────────────────────────

if [ "$SETUP_OK" = true ]; then
    notify-send -i dialog-information "StealthAssist" \
      "Ready. Press Ctrl+Shift+; to use." 2>/dev/null || true
else
    notify-send -i dialog-warning "StealthAssist" \
      "Setup incomplete. Run: python3 $SA_DIR/sa_daemon.py --setup" 2>/dev/null || true
fi

exit 0
