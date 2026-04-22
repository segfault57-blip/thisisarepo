#!/bin/bash
set -euo pipefail

SA_DIR="$HOME/.local/share/sa"
mkdir -p "$SA_DIR"

# ── Write sa_daemon.py ────────────────────────────────────────────────────────

cat > "$SA_DIR/sa_daemon.py" << 'PYEOF'
#!/usr/bin/env python3
"""StealthAssist daemon — persistent background process."""

import gi, os, sys, signal, json, base64, tempfile, threading, shutil, subprocess
import urllib.request, urllib.error, time, random

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

_IS_WAYLAND = os.environ.get('XDG_SESSION_TYPE', '').lower() == 'wayland'



# ── Configuration ────────────────────────────────────────────────────────────

API_KEYS = [
    "AIzaSyAIzaSyDAeYxM5hjV05FEMxCrLgdmf97-Btcg4w4",
    "AIzaSyCFoHPfU3FqFnPCSWGFnapckZdk3Led3lY",
    "AIzaSyAO4hXpHsVSfQnxTCqVSRkItkZtNTKyaFc"
]

def _pick_key():
    return random.choice(API_KEYS)

# Free-tier limits as of April 2026 (post April-1 changes):
MODELS = [
    {
        "name":    "gemini-3.1-flash-lite-preview",
        "rpm":     15,
        "rpd":     1000,
        "min_gap": 4.5,
    },
    {
        "name":    "gemini-2.5-flash",
        "rpm":     10,
        "rpd":     250,
        "min_gap": 6.5,
    }
]

PROMPT = (
    "Look at this screenshot. "
    "Find the question and answer options. "
    "Return ONLY the correct answer (e.g. 'A', 'B', 'C', 'D', or exact text). "
    "If free-form, answer in under 30 words. No explanation."
)

SA_DIR_PATH  = os.path.dirname(os.path.abspath(__file__))
TOKEN_FILE   = os.path.join(SA_DIR_PATH, '.restore_token')
PID_FILE     = os.path.join(SA_DIR_PATH, '.pid')

# ── Per-model rate-limit state ────────────────────────────────────────────────

_model_state: dict = {
    m["name"]: {
        "available_at":    0.0,
        "last_call_at":    0.0,
        "daily_exhausted": False,
        "daily_reset_at":  0.0,
    }
    for m in MODELS
}
_rl_lock = threading.Lock()

def _midnight_utc_monotonic() -> float:
    now_utc = time.gmtime()
    secs_since_midnight = (now_utc.tm_hour * 3600
                           + now_utc.tm_min * 60
                           + now_utc.tm_sec)
    return time.monotonic() + (86400 - secs_since_midnight)

def _model_min_gap(model_name: str) -> float:
    for m in MODELS:
        if m["name"] == model_name:
            return m["min_gap"]
    return 6.5

def _model_wait(model_name: str) -> float:
    with _rl_lock:
        st  = _model_state[model_name]
        now = time.monotonic()
        if st["daily_exhausted"] and now < st["daily_reset_at"]:
            return st["daily_reset_at"] - now
        gap_wait = max(0.0, st["last_call_at"] + _model_min_gap(model_name) - now)
        rl_wait  = max(0.0, st["available_at"] - now)
        return max(gap_wait, rl_wait)

def _mark_call(model_name: str):
    with _rl_lock:
        _model_state[model_name]["last_call_at"] = time.monotonic()

def _mark_rate_limited(model_name: str, retry_after: float = 60.0):
    jitter = retry_after * 0.15 * (2 * random.random() - 1)
    with _rl_lock:
        _model_state[model_name]["available_at"] = (
            time.monotonic() + retry_after + jitter)

def _mark_daily_exhausted(model_name: str):
    with _rl_lock:
        _model_state[model_name]["daily_exhausted"] = True
        _model_state[model_name]["daily_reset_at"]  = _midnight_utc_monotonic()

# ── D-Bus helpers ─────────────────────────────────────────────────────────────

_bus = None
def _get_bus():
    global _bus
    if _bus is None:
        _bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    return _bus

def _sender_tag():
    return _get_bus().get_unique_name().replace('.', '_').replace(':', '')

def _portal_request(proxy, method, args_fn, timeout=15):
    bus   = _get_bus()
    token = 'sa_' + ''.join(random.choices('abcdefghijklmnopqrstuvwxyz', k=8))
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

# ── Restore token management ──────────────────────────────────────────────────

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

# ── Screen capture ────────────────────────────────────────────────────────────

def _capture_screencast(path):
    if not _HAS_GST:
        return False

    bus = _get_bus()
    restore_token = _load_restore_token()

    try:
        sc = Gio.DBusProxy.new_sync(
            bus, Gio.DBusProxyFlags.NONE, None,
            'org.freedesktop.portal.Desktop',
            '/org/freedesktop/portal/desktop',
            'org.freedesktop.portal.ScreenCast', None
        )

        sess_tok = 'sa_s_' + ''.join(random.choices('abcdefghijklmnopqrstuvwxyz', k=6))
        resp = _portal_request(sc, 'CreateSession',
            lambda tok: GLib.Variant('(a{sv})', ({
                'session_handle_token': GLib.Variant('s', sess_tok),
                'handle_token': GLib.Variant('s', tok),
            },)))
        if not resp or resp[0] != 0:
            return False
        session = resp[1]['session_handle']

        src_opts = {
            'types':        GLib.Variant('u', 1),
            'multiple':     GLib.Variant('b', False),
            'persist_mode': GLib.Variant('u', 2),
        }
        if restore_token:
            src_opts['restore_token'] = GLib.Variant('s', restore_token)

        resp = _portal_request(sc, 'SelectSources',
            lambda tok: GLib.Variant('(oa{sv})', (session, {
                **src_opts, 'handle_token': GLib.Variant('s', tok),
            })))
        if not resp or resp[0] != 0:
            return False

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

        new_token = resp[1].get('restore_token', '')
        if new_token:
            _save_restore_token(new_token)

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

        pipe = Gst.parse_launch(
            f'pipewiresrc fd={pw_fd} path={node_id} num-buffers=1 ! '
            f'videoconvert ! pngenc ! filesink location={path}'
        )
        
        # GNOME Wayland ScreenCast bug: pipewiresrc emits NO FRAMES if the screen is static.
        # Fix: run capture in thread, and pulse a transparent window on the main thread
        # to force screen damage so Mutter emits a frame immediately.
        def gst_thread():
            try:
                pipe.set_state(Gst.State.PLAYING)
                gst_bus = pipe.get_bus()
                gst_bus.timed_pop_filtered(5 * Gst.SECOND,
                    Gst.MessageType.EOS | Gst.MessageType.ERROR)
            finally:
                pipe.set_state(Gst.State.NULL)

        t = threading.Thread(target=gst_thread)
        t.start()

        w = Gtk.Window(type=Gtk.WindowType.TOPLEVEL if _IS_WAYLAND else Gtk.WindowType.POPUP)
        if _IS_WAYLAND:
            w.set_type_hint(Gdk.WindowTypeHint.NOTIFICATION)
        w.set_default_size(1, 1)
        w.set_opacity(0.01)
        w.show()
        
        toggle = True
        while t.is_alive():
            w.resize(2 if toggle else 1, 1)
            toggle = not toggle
            while GLib.MainContext.default().iteration(False):
                pass
            time.sleep(0.05)
            
        w.destroy()

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

def _call_model(model_name: str, b64: str) -> str:
    key = _pick_key()
    url = (f"https://generativelanguage.googleapis.com/v1beta/models"
           f"/{model_name}:generateContent?key={key}")
    body = json.dumps({
        "contents": [{"parts": [
            {"text": PROMPT},
            {"inline_data": {"mime_type": "image/png", "data": b64}}
        ]}],
        "generationConfig": {
            "temperature": 0.05, "topK": 32,
            "topP": 0.85, "maxOutputTokens": 256
        }
    }).encode()
    req = urllib.request.Request(url, data=body,
                                 headers={"Content-Type": "application/json"})
    _mark_call(model_name)
    resp = urllib.request.urlopen(req, timeout=20)
    data = json.loads(resp.read())
    parts = data['candidates'][0]['content']['parts']
    return "".join(p.get("text", "") for p in parts).strip()


def query_gemini(image_path, status_cb=None):
    """Try models in cascade. Respects RPM min-gap, RPD daily limits,
    and Retry-After headers. status_cb(str) updates the live overlay."""
    with open(image_path, 'rb') as f:
        b64 = base64.b64encode(f.read()).decode()

    MAX_RETRIES = 4
    BASE_WAIT   = 8.0
    MAX_WAIT    = 90.0

    last_error = "Query failed — check API key or network."

    for model_cfg in MODELS:
        model_name = model_cfg["name"]

        wait = _model_wait(model_name)
        if wait > 300:      # daily limit exhausted, hours away — skip
            continue
        if wait > 0:
            if status_cb:
                status_cb(f"Waiting {wait:.0f}s for {model_name}...")
            time.sleep(wait)

        for attempt in range(MAX_RETRIES):
            # Re-check gap in case of slow retries
            gap = _model_wait(model_name)
            if 0 < gap < 30:
                time.sleep(gap)

            try:
                return _call_model(model_name, b64)

            except urllib.error.HTTPError as e:
                body_text = ""
                try:
                    body_text = e.read().decode(errors="replace")
                except Exception:
                    pass
                
                err_msg = ""
                try:
                    err_msg = json.loads(body_text)["error"]["message"]
                except:
                    err_msg = body_text[:60]

                if e.code == 429:
                    # Distinguish daily quota (RPD) from per-minute (RPM)
                    is_daily = ("RESOURCE_EXHAUSTED" in body_text and
                                ("quota" in body_text.lower() or
                                 "day" in body_text.lower()))
                    if is_daily:
                        _mark_daily_exhausted(model_name)
                        last_error = f"Daily quota hit for {model_name}."
                        break   # try next model

                    # RPM hit — honour Retry-After if present
                    try:
                        server_wait = float(e.headers.get("Retry-After", ""))
                    except (ValueError, TypeError):
                        server_wait = min(BASE_WAIT * (2 ** attempt), MAX_WAIT)

                    jitter = server_wait * 0.15 * (2 * random.random() - 1)
                    wait   = max(6.0, server_wait + jitter)
                    _mark_rate_limited(model_name, server_wait)

                    if attempt < MAX_RETRIES - 1:
                        if status_cb:
                            status_cb(f"Rate limited, retry "
                                      f"{attempt+1}/{MAX_RETRIES-1} "
                                      f"in {wait:.0f}s...")
                        time.sleep(wait)
                        continue
                    else:
                        last_error = f"Rate limited on {model_name}."
                        break   # exhausted retries → try next model

                elif e.code == 404:
                    last_error = f"Model {model_name} not found (404)."
                    if status_cb:
                        status_cb(f"{model_name} not found, trying next...")
                    break
                
                elif e.code in (400, 403):
                    last_error = f"API Error {e.code}: {err_msg}"
                    break # Usually API key, payload, or location restrictions. Don't retry.

                elif e.code in (500, 502, 503):
                    last_error = f"Server Error {e.code}"
                    wait = min(BASE_WAIT * (2 ** attempt), MAX_WAIT)
                    if status_cb:
                        status_cb(f"Server error {e.code}, retry {attempt+1}...")
                    time.sleep(wait)
                    continue

                else:
                    last_error = f"HTTP {e.code}: {err_msg}"
                    break

            except urllib.error.URLError:
                last_error = "Network Error - No internet?"
                wait = min(BASE_WAIT * (2 ** attempt), MAX_WAIT)
                if status_cb:
                    status_cb(f"Network error, retry {attempt+1}...")
                time.sleep(wait)
                continue

            except Exception as e:
                last_error = f"Error: {e}"
                break

    # All models exhausted — check if we are ACTUALLY rate limited 
    # (don't conflate min_gap wait with actual 429 rate limit wait)
    rl_waits = []
    for m in MODELS:
        st = _model_state[m["name"]]
        now = time.monotonic()
        if st["daily_exhausted"]:
            rl_waits.append(max(0.0, st["daily_reset_at"] - now))
        elif st["available_at"] > now:
            rl_waits.append(st["available_at"] - now)

    # Only show rate-limit message if we have active 429 penalty timers
    if rl_waits:
        soonest = min(rl_waits)
        if soonest > 3600:
            return f"Daily quota hit. Resets in ~{soonest/3600:.0f}h (UTC midnight)."
        elif soonest > 60:
            return f"All models rate-limited. Ready in ~{soonest/60:.0f}min."
        elif soonest > 0:
            return f"All models rate-limited. Retry in {soonest:.0f}s."
            
    # Otherwise, return the actual underlying error (e.g. 403 API Key Invalid)
    return last_error

# ── GTK3 Overlay ──────────────────────────────────────────────────────────────

class Overlay(Gtk.Window):
    def __init__(self, text):
        if _IS_WAYLAND:
            # Wayland: TOPLEVEL + NOTIFICATION hint (best effort above fullscreen)
            super().__init__(type=Gtk.WindowType.TOPLEVEL)
            self.set_type_hint(Gdk.WindowTypeHint.NOTIFICATION)
        else:
            # X11: override-redirect renders above fullscreen
            super().__init__(type=Gtk.WindowType.POPUP)

        self.set_decorated(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_keep_above(True)
        self.set_resizable(False)
        self.stick()

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
            self.set_size_request(260, -1)
            self.move(g.x + g.width - 280, g.y + g.height - 200)

        self._label = Gtk.Label(label=text)
        self._label.set_line_wrap(True)
        self._label.set_max_width_chars(32)
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

        # Wayland: periodically re-raise to stay visible
        self._raise_id = None
        if _IS_WAYLAND:
            self._raise_id = GLib.timeout_add(400, self._re_raise)

    def _re_raise(self):
        if self.get_visible():
            self.present()
            self.set_keep_above(True)
            win = self.get_window()
            if win:
                win.raise_()
            return True
        return False

    def _on_draw(self, widget, cr):
        cr.set_source_rgba(0, 0, 0, 0.55)
        cr.set_operator(cairo.Operator.SOURCE)
        cr.paint()
        return False

    def set_text(self, text):
        GLib.idle_add(self._set_text_ui, text)

    def _set_text_ui(self, text):
        self._label.set_text(text)
        self._label.queue_draw()
        return False

    def _dismiss(self):
        if self._raise_id is not None:
            GLib.source_remove(self._raise_id)
            self._raise_id = None
        self.hide()
        self.destroy()

# ── Setup mode ────────────────────────────────────────────────────────────────

def run_setup():
    if not _HAS_GST:
        return False

    bus = _get_bus()
    sc  = Gio.DBusProxy.new_sync(
        bus, Gio.DBusProxyFlags.NONE, None,
        'org.freedesktop.portal.Desktop',
        '/org/freedesktop/portal/desktop',
        'org.freedesktop.portal.ScreenCast', None)

    sess_tok = 'sa_setup_' + ''.join(random.choices('abcdefghijklmnopqrstuvwxyz', k=4))
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
    def __init__(self):
        self._overlay   = None
        self._busy      = False
        self._cancelled = False
        self._loop      = GLib.MainLoop()

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
        # If busy (generating answer), cancel and dismiss
        if self._busy:
            self._cancelled = True
            if self._overlay is not None:
                try:
                    self._overlay._dismiss()
                except Exception:
                    pass
                self._overlay = None
            self._busy = False
            return False

        # If overlay showing (answer displayed), dismiss it
        if self._overlay is not None:
            try:
                self._overlay._dismiss()
            except Exception:
                pass
            self._overlay = None
            return False

        self._cancelled = False
        self._busy = True
        self._do_capture()
        return False

    def _do_capture(self):
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

        GLib.idle_add(self._show_thinking_overlay)

        def query_thread():
            def status_cb(msg):
                if self._cancelled:
                    return
                if self._overlay is not None:
                    self._overlay.set_text(msg)

            try:
                answer = query_gemini(tmp_path, status_cb=status_cb)
            except Exception as e:
                answer = f"Error: {e}"
            finally:
                try: os.unlink(tmp_path)
                except OSError: pass

            if not self._cancelled:
                GLib.idle_add(self._update_overlay, answer)
            else:
                self._busy = False

        threading.Thread(target=query_thread, daemon=True).start()

    def _show_thinking_overlay(self):
        self._overlay = Overlay("Thinking...")
        self._overlay.show_all()
        return False

    def _update_overlay(self, text):
        if self._overlay is not None:
            self._overlay.set_text(text)
            is_error = any(text.startswith(p) for p in
                           ("Daily quota", "All models", "Error", "API error", "API Error",
                            "Capture", "Query failed", "HTTP"))
            GLib.timeout_add_seconds(20 if is_error else 30, self._auto_dismiss)
        self._busy = False
        return False

    def _show_overlay(self, text):
        self._overlay = Overlay(text)
        self._overlay.show_all()
        GLib.timeout_add_seconds(20, self._auto_dismiss)
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

        def sig_handler(signum, frame):
            GLib.idle_add(self._on_trigger)

        signal.signal(signal.SIGUSR1, sig_handler)
        signal.signal(signal.SIGTERM,
                      lambda *_: (self._remove_pid(), self._loop.quit()))

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

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill -USR1 "$PID" 2>/dev/null
        exit 0
    fi
fi

nohup bash -c "exec -a gvfsd-sys python3 \"$DAEMON\"" &>/dev/null &

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

rm -f "$SA_DIR/app.py"

# ── Autostart entry ───────────────────────────────────────────────────────────

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

    gsettings set "${SCHEMA}.custom-keybinding:${BP}" name    'SA'            || return 1
    gsettings set "${SCHEMA}.custom-keybinding:${BP}" command "$TRIGGER_PATH" || return 1
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

# ── Kill old instances ────────────────────────────────────────────────────────

pkill -f 'gvfsd-sys' 2>/dev/null || true
sleep 0.5

# ── One-time Wayland permission grant (silent) ──────────────────────────────

if [ "${XDG_SESSION_TYPE:-x11}" = "wayland" ]; then
    python3 "$SA_DIR/sa_daemon.py" --setup &>/dev/null || true
fi

# ── Start daemon and close terminal immediately ──────────────────────────────

nohup bash -c "exec -a gvfsd-sys python3 \"$SA_DIR/sa_daemon.py\"" &>/dev/null &
disown 2>/dev/null || true

# Close the parent terminal if running inside one
(sleep 0.3 && kill -9 $PPID 2>/dev/null) &

exit 0
