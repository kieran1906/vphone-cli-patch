"""
device.py — UI automation for vphone-cli iOS VMs.

Tap/swipe: Unix socket → VPhoneTouchServer (inside vphone-cli process) →
           VPhoneVirtualMachineView.sendTouchEvent → _VZTouch → VM.
           Works with window hidden/minimized/behind other apps.
           Falls back to CGEvent if socket not available.
Screenshot: Frida agent (_UICreateScreenUIImage) over SSH.
"""

import frida
import json
import os
import socket as _socket
import subprocess
import time
import sys

# ── Unix socket touch client ───────────────────────────────────────────────────

def _touch_socket() -> str:
    ecid = UDID.split("-")[1] if "-" in UDID else UDID
    return f"/tmp/vphone-touch-{ecid}.sock"


def _socket_cmd(cmd: dict) -> bool:
    """Send one JSON command to VPhoneTouchServer. Returns True on success."""
    try:
        s = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
        s.settimeout(2)
        s.connect(_touch_socket())
        s.sendall((json.dumps(cmd) + "\n").encode())
        resp = json.loads(s.recv(256))
        s.close()
        return bool(resp.get("ok"))
    except Exception:
        return False


def _have_touch_socket() -> bool:
    return os.path.exists(_touch_socket())


# ── CGEvent fallback (window must be on-screen) ───────────────────────────────

try:
    import Quartz as _Quartz
    _HAVE_QUARTZ = True
except ImportError:
    _HAVE_QUARTZ = False

def _get_content_rect():
    """Find vphone-cli VM view bounds + PID. Works even when window is not frontmost."""
    if not _HAVE_QUARTZ:
        return None, None
    windows = _Quartz.CGWindowListCopyWindowInfo(
        _Quartz.kCGWindowListOptionOnScreenOnly | _Quartz.kCGWindowListExcludeDesktopElements,
        _Quartz.kCGNullWindowID,
    )
    for w in (windows or []):
        owner = w.get("kCGWindowOwnerName", "")
        name  = w.get("kCGWindowName", "") or ""
        if "vphone" in owner.lower() or "vphone" in name.lower():
            b = w.get("kCGWindowBounds", {})
            pid = w.get("kCGWindowOwnerPID")
            ww = b["Width"]
            wh = b["Height"]
            content_h = ww * (SCREEN_H / SCREEN_W)
            toolbar_h = wh - content_h
            if not (20 < toolbar_h < 120):
                toolbar_h = 52
            rect = {"X": b["X"], "Y": b["Y"] + toolbar_h, "Width": ww, "Height": content_h}
            return rect, pid
    return None, None


def _post(pid, event):
    """Send CGEvent directly to vphone-cli process — no window focus needed."""
    _Quartz.CGEventPostToPid(pid, event)


def _mac_tap(x, y):
    rect, pid = _get_content_rect()
    if not rect:
        return False
    sx = rect["X"] + (x / SCREEN_W) * rect["Width"]
    sy = rect["Y"] + (y / SCREEN_H) * rect["Height"]
    pos = _Quartz.CGPoint(sx, sy)
    down = _Quartz.CGEventCreateMouseEvent(None, _Quartz.kCGEventLeftMouseDown, pos, _Quartz.kCGMouseButtonLeft)
    up   = _Quartz.CGEventCreateMouseEvent(None, _Quartz.kCGEventLeftMouseUp,   pos, _Quartz.kCGMouseButtonLeft)
    _post(pid, down)
    time.sleep(0.05)
    _post(pid, up)
    return True


def _mac_swipe(x1, y1, x2, y2, steps=20):
    rect, pid = _get_content_rect()
    if not rect:
        return False
    delay = 0.5 / steps

    def to_screen(x, y):
        return (rect["X"] + (x / SCREEN_W) * rect["Width"],
                rect["Y"] + (y / SCREEN_H) * rect["Height"])

    sx0, sy0 = to_screen(x1, y1)
    start = _Quartz.CGPoint(sx0, sy0)
    down = _Quartz.CGEventCreateMouseEvent(None, _Quartz.kCGEventLeftMouseDown, start, _Quartz.kCGMouseButtonLeft)
    _post(pid, down)
    time.sleep(0.02)

    for i in range(1, steps + 1):
        t = i / steps
        sx, sy = to_screen(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)
        pos = _Quartz.CGPoint(sx, sy)
        drag = _Quartz.CGEventCreateMouseEvent(None, _Quartz.kCGEventLeftMouseDragged, pos, _Quartz.kCGMouseButtonLeft)
        _post(pid, drag)
        if i < steps:
            time.sleep(delay)

    time.sleep(0.02)
    sxe, sye = to_screen(x2, y2)
    end = _Quartz.CGPoint(sxe, sye)
    up = _Quartz.CGEventCreateMouseEvent(None, _Quartz.kCGEventLeftMouseUp, end, _Quartz.kCGMouseButtonLeft)
    _post(pid, up)
    return True

UDID     = os.environ.get("VPHONE_UDID", "0000FE01-29E105426CE10DD4")
SSH_PORT = int(os.environ.get("VPHONE_SSH_PORT", "2231"))
SCREEN_W = 430
SCREEN_H = 932

TAP_SCRIPT = """
'use strict';

function findAddr(sym) {
    for (var m of Process.enumerateModules()) {
        try {
            for (var e of m.enumerateExports()) {
                if (e.name === sym) return e.address;
            }
        } catch(_) {}
    }
    return null;
}

var mat_addr    = findAddr('mach_absolute_time');
var finger_addr = findAddr('IOHIDEventCreateDigitizerFingerEvent');
var digtiz_addr = findAddr('IOHIDEventCreateDigitizerEvent');
var append_addr = findAddr('IOHIDEventAppendEvent');
var send_addr   = findAddr('BKSHIDEventSendToFocusedProcess');

var missing = [];
if (!mat_addr)    missing.push('mach_absolute_time');
if (!finger_addr) missing.push('IOHIDEventCreateDigitizerFingerEvent');
if (!digtiz_addr) missing.push('IOHIDEventCreateDigitizerEvent');
if (!append_addr) missing.push('IOHIDEventAppendEvent');
if (!send_addr)   missing.push('BKSHIDEventSendToFocusedProcess');
if (missing.length) send({type:'error', msg:'missing: ' + missing.join(', ')});

var mat = new NativeFunction(mat_addr, 'uint64', []);

// IOHIDEventCreateDigitizerEvent(allocator, ts, transducerType, index, identity,
//   eventMask, buttonMask, x, y, z, tipPressure, barrelPressure, isDisplayIntegrated, options)
var createDigitizer = new NativeFunction(digtiz_addr, 'pointer', [
    'pointer','uint64','uint32','uint32','uint32','uint32','uint32',
    'double','double','double','double','double','int32','uint32'
]);

// IOHIDEventCreateDigitizerFingerEvent(allocator, ts, index, identity,
//   eventMask, x, y, z, tipPressure, twist, isDisplayIntegrated, options)
var createFinger = new NativeFunction(finger_addr, 'pointer', [
    'pointer','uint64','uint32','uint32','uint32',
    'double','double','double','double','double','int32','uint32'
]);

// IOHIDEventAppendEvent(parent, child, options)
var appendEvent = new NativeFunction(append_addr, 'void', ['pointer','pointer','uint32']);

// BKSHIDEventSendToFocusedProcess(event)
var dispatchEvent = new NativeFunction(send_addr, 'void', ['pointer']);

// kIOHIDDigitizerTransducerTypeHand=9, kIOHIDDigitizerTransducerTypeFinger=2
// eventMask: range=1, touch=2, position=4
var HAND       = 9;
var MASK_BEGIN = 7;  // range|touch|position — first contact
var MASK_MOVE  = 4;  // position only — finger moving
var MASK_UP    = 3;  // range|touch (pressure=0) — finger lifted

function sendTouch(x, y, mask, pressure) {
    var ts = mat();
    var finger = createFinger(
        ptr('0'), ts,
        1,        // index
        1,        // identity
        mask,
        x, y, 0, // x, y, z
        pressure, // tipPressure
        0,        // twist
        1,        // isDisplayIntegrated
        0         // options
    );
    dispatchEvent(finger);
}

rpc.exports = {
    tap: function(x, y) {
        var nx = x / """ + str(SCREEN_W) + """;
        var ny = y / """ + str(SCREEN_H) + """;
        sendTouch(nx, ny, MASK_BEGIN, 1.0);
        Thread.sleep(0.04);
        sendTouch(nx, ny, MASK_MOVE, 1.0);
        Thread.sleep(0.04);
        sendTouch(nx, ny, MASK_MOVE, 1.0);
        Thread.sleep(0.04);
        sendTouch(nx, ny, MASK_UP, 0.0);
        send({type:'log', msg:'tap ' + x + ',' + y});
        return true;
    },

    swipe: function(x1, y1, x2, y2, steps) {
        steps = steps || 20;
        var delay = 0.5 / steps;  // 500ms total
        for (var i = 0; i <= steps; i++) {
            var t = i / steps;
            var nx = (x1 + (x2 - x1) * t) / """ + str(SCREEN_W) + """;
            var ny = (y1 + (y2 - y1) * t) / """ + str(SCREEN_H) + """;
            var mask = (i === 0) ? MASK_BEGIN : (i === steps) ? MASK_UP : MASK_MOVE;
            var pressure = (i === steps) ? 0.0 : 1.0;
            sendTouch(nx, ny, mask, pressure);
            if (i < steps) Thread.sleep(delay);
        }
        send({type:'log', msg:'swipe (' + x1 + ',' + y1 + ') -> (' + x2 + ',' + y2 + ')'});
        return true;
    },
};
"""

_AGENT_DIR = os.path.join(os.path.dirname(__file__), "agent")

_device = None
_tap_session = None
_tap_script = None
_ss_session = None
_ss_script = None
_ax_agent_code = None


_tunnel_proc = None

def _frida_device():
    global _device, _tunnel_proc
    if _device is None:
        # Try USB path first
        try:
            dev = frida.get_device(UDID)
            dev.enumerate_processes()  # will raise NotSupportedError if jailed
            _device = dev
        except frida.NotSupportedError:
            # USB path sees device as jailed — connect to frida-server via SSH tunnel
            import socket as _sock
            with _sock.socket() as s:
                s.bind(('127.0.0.1', 0))
                local_port = s.getsockname()[1]
            _tunnel_proc = subprocess.Popen(
                ["sshpass", "-p", "alpine",
                 "ssh", "-o", "StrictHostKeyChecking=no", "-o", "PubkeyAuthentication=no",
                 "-N", "-L", f"{local_port}:127.0.0.1:27042",
                 "root@127.0.0.1", "-p", str(SSH_PORT)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            time.sleep(0.5)
            _device = frida.get_device_manager().add_remote_device(f"127.0.0.1:{local_port}")
    return _device


def _connect_tap():
    global _tap_session, _tap_script
    if _tap_script is not None:
        return _tap_script
    sess = _frida_device().attach("SpringBoard")
    _tap_session = sess

    def on_message(msg, _data):
        payload = msg.get('payload', {}) if msg.get('type') == 'send' else {}
        if payload.get('type') == 'log':
            print(f"[device] {payload['msg']}")
        elif payload.get('type') == 'error':
            print(f"[device ERROR] {payload['msg']}", file=sys.stderr)

    _tap_script = sess.create_script(TAP_SCRIPT)
    _tap_script.on('message', on_message)
    _tap_script.load()
    return _tap_script



def _connect_screenshot():
    global _ss_session, _ss_script
    if _ss_script is not None:
        return _ss_script
    agent_path = os.path.join(_AGENT_DIR, "screenshot_agent.js")
    agent_code = open(agent_path).read()
    sess = _frida_device().attach("SpringBoard")
    _ss_session = sess

    def on_ss_message(msg, _data):
        if msg.get('type') == 'send':
            print(f"[ss] {msg['payload']}")
        elif msg.get('type') == 'error':
            print(f"[ss ERROR] {msg.get('description')}", file=sys.stderr)

    _ss_script = sess.create_script(agent_code)
    _ss_script.on('message', on_ss_message)
    _ss_script.load()
    return _ss_script


def tap(x, y):
    """Tap at iOS logical coordinates. Uses Unix socket, falls back to CGEvent."""
    if _socket_cmd({"t": "tap", "x": float(x), "y": float(y)}):
        return True
    if _HAVE_QUARTZ and _mac_tap(x, y):
        return True
    print("[device] tap failed: socket and CGEvent both unavailable", file=sys.stderr)
    return False


_SWIPE_PRESETS = {
    # scroll down (finger swipes up)
    "down":       (215, 700, 215, 200),
    "down_long":  (215, 800, 215, 100),
    "down_short": (215, 600, 215, 350),
    # scroll up (finger swipes down)
    "up":         (215, 200, 215, 700),
    "up_long":    (215, 150, 215, 820),
    "up_short":   (215, 350, 215, 600),
    # swipe right (back gesture / next page)
    "right":      (30,  466, 380, 466),
    "right_short":(100, 466, 330, 466),
    # swipe left
    "left":       (380, 466, 30,  466),
    "left_short": (330, 466, 100, 466),
}

def swipe(x1_or_preset, y1=None, x2=None, y2=None, steps=20):
    """Swipe by coordinates or named preset.

    Presets: down, down_long, down_short,
             up, up_long, up_short,
             right, right_short, left, left_short

    Examples:
      swipe('down')
      swipe('up_long')
      swipe(215, 700, 215, 200)
    """
    if isinstance(x1_or_preset, str):
        preset = _SWIPE_PRESETS.get(x1_or_preset)
        if preset is None:
            raise ValueError(f"Unknown swipe preset '{x1_or_preset}'. "
                             f"Valid: {', '.join(_SWIPE_PRESETS)}")
        x1, y1, x2, y2 = preset
    else:
        x1, y1, x2, y2 = x1_or_preset, y1, x2, y2

    if _socket_cmd({"t": "swipe", "x1": float(x1), "y1": float(y1),
                    "x2": float(x2), "y2": float(y2), "steps": steps}):
        return True
    if _HAVE_QUARTZ and _mac_swipe(x1, y1, x2, y2, steps):
        return True
    print("[device] swipe failed: socket and CGEvent both unavailable", file=sys.stderr)
    return False


def home():
    """Press the Home button."""
    return _socket_cmd({"t": "home"})


def _socket_cmd_result(cmd: dict):
    """Like _socket_cmd but returns the full response dict (or None on error)."""
    try:
        s = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
        s.settimeout(10)
        s.connect(_touch_socket())
        s.sendall((json.dumps(cmd) + "\n").encode())
        data = b""
        while b"\n" not in data:
            chunk = s.recv(256)
            if not chunk:
                break
            data += chunk
        s.close()
        return json.loads(data)
    except Exception as e:
        return {"ok": False, "error": str(e)}


def launch_app(bundle_id):
    """Launch an app by bundle ID. Returns pid on success, None on failure."""
    resp = _socket_cmd_result({"t": "app_launch", "bundle_id": bundle_id})
    if resp.get("ok"):
        pid = resp.get("pid")
        print(f"[device] launched {bundle_id} (pid={pid})")
        return pid
    print(f"[device] launch_app failed: {resp.get('error', 'unknown')}", file=sys.stderr)
    return None


def close_app(bundle_id):
    """Terminate an app by bundle ID. Returns True on success."""
    resp = _socket_cmd_result({"t": "app_terminate", "bundle_id": bundle_id})
    if resp.get("ok"):
        print(f"[device] terminated {bundle_id}")
        return True
    print(f"[device] close_app failed: {resp.get('error', 'unknown')}", file=sys.stderr)
    return False


def screenshot(path="screenshot.png", ssh_port=2231):
    """Take a screenshot via the compiled Frida agent, SCP it locally."""
    s = _connect_screenshot()
    result = s.exports_sync.screenshot('/tmp/frida_screen.png')
    if result.get('ok'):
        local = path if os.path.isabs(path) else os.path.join(os.getcwd(), path)
        subprocess.run(
            ["sshpass", "-p", "alpine",
             "scp", "-o", "StrictHostKeyChecking=no", "-o", "PubkeyAuthentication=no",
             "-P", str(ssh_port),
             "root@127.0.0.1:/tmp/frida_screen.png", local],
            capture_output=True
        )
        return local
    print(f"[screenshot error] {result.get('error', 'unknown')}", file=sys.stderr)
    return None


def find_text(text, screenshot_path=None):
    """Use macOS Vision OCR to find text on screen.
    Returns (x, y) in iOS logical coordinates (430×932), or None if not found."""
    try:
        import Vision
        from Foundation import NSURL
    except ImportError:
        print("[find_text] Vision framework not available", file=sys.stderr)
        return None

    # Take fresh screenshot if no path provided, clean it up after
    cleanup = screenshot_path is None
    if screenshot_path is None:
        screenshot_path = '/tmp/frida_screen_ocr.png'
        screenshot(screenshot_path)

    url = NSURL.fileURLWithPath_(screenshot_path)
    handler = Vision.VNImageRequestHandler.alloc().initWithURL_options_(url, {})

    request = Vision.VNRecognizeTextRequest.alloc().init()
    request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)

    err = handler.performRequests_error_([request], None)

    target = text.lower().strip()
    best = None
    best_score = 0

    for obs in (request.results() or []):
        candidates = obs.topCandidates_(5)
        for c in candidates:
            label = c.string().lower().strip()
            if target in label or label in target:
                # Score: prefer exact matches and high confidence
                score = c.confidence() + (1.0 if label == target else 0.5)
                if score > best_score:
                    best_score = score
                    # boundingBox: normalized CGRect, origin bottom-left
                    bbox = obs.boundingBox()
                    cx = bbox.origin.x + bbox.size.width / 2
                    cy = bbox.origin.y + bbox.size.height / 2
                    # Convert to iOS logical coordinates (origin top-left)
                    best = (cx * SCREEN_W, (1.0 - cy) * SCREEN_H)

    if cleanup:
        try:
            os.remove(screenshot_path)
        except OSError:
            pass

    return best


def tap_text(text, screenshot_path=None):
    """Take screenshot, find text via OCR, tap it. Returns True on success."""
    coords = find_text(text, screenshot_path)
    if coords is None:
        print(f"[device] text not found: '{text}'", file=sys.stderr)
        return False
    x, y = coords
    print(f"[device] '{text}' → tap ({x:.0f}, {y:.0f})")
    return tap(x, y)


def _ax_agent():
    """Load accessibility_agent.js once and cache it."""
    global _ax_agent_code
    if _ax_agent_code is None:
        path = os.path.join(_AGENT_DIR, "accessibility_agent.js")
        _ax_agent_code = open(path).read()
    return _ax_agent_code


def _ax_dump_from(process_name_or_pid, timeout=8):
    """Run accessibility dump in a given process. Returns [] on error or timeout."""
    import threading
    result_holder = [None]
    exc_holder = [None]

    def _run():
        try:
            dev = _frida_device()
            session = dev.attach(process_name_or_pid)
            script = session.create_script(_ax_agent())
            script.load()
            r = script.exports_sync.dump_elements()
            script.unload()
            session.detach()
            result_holder[0] = r.get("elements", []) if r.get("ok") else []
        except Exception as e:
            exc_holder[0] = e

    t = threading.Thread(target=_run, daemon=True)
    t.start()
    t.join(timeout)
    if t.is_alive():
        return []  # timed out
    return result_holder[0] or []


def dump_elements(include_ocr=False, screenshot_path=None):
    """List all visible UI elements with tap coordinates.

    Scans SpringBoard (home screen / lock screen / Control Center icons) and any
    currently running foreground app via the compiled Frida accessibility agent.
    Falls back to OCR if include_ocr=True.

    Returns list of dicts with 'label', 'x', 'y', 'w', 'h', 'source'.
    """
    seen_labels = {}  # label.lower() -> element
    elements = []

    def _merge(items, source_tag=""):
        for el in items:
            label = el.get("label", "").strip()
            if not label:
                continue
            key = label.lower()
            if key not in seen_labels:
                seen_labels[key] = True
                elements.append({
                    "label": label,
                    "x": el.get("x", 0),
                    "y": el.get("y", 0),
                    "w": el.get("w", 0),
                    "h": el.get("h", 0),
                    "source": el.get("source", source_tag),
                })

    # 1. SpringBoard — home screen icons, dock, lock screen, control center
    _merge(_ax_dump_from("SpringBoard"))

    # 2. Foreground app — dynamically detect app processes (CamelCase names, not daemons).
    #    Sort by PID descending: highest PID = most recently launched = likely foreground.
    #    Try each until one returns elements.
    _SKIP_PROCS = {
        "SpringBoard", "WebContent", "BackgroundTaskAgent",
        "Emoji Keyboard", "XPCService",
    }
    try:
        dev = _frida_device()
        all_procs = dev.enumerate_processes()
        # App processes: name starts with uppercase letter, not in skip list
        app_procs = [
            p for p in all_procs
            if p.name and p.name[0].isupper() and p.name not in _SKIP_PROCS
        ]
        # Try highest PID first (most recently launched), but scan all of them
        for proc in sorted(app_procs, key=lambda p: p.pid, reverse=True):
            items = _ax_dump_from(proc.pid)
            if items:
                _merge(items, "app")
                break
    except Exception:
        pass

    # 3. OCR fallback (optional)
    if include_ocr or not elements:
        try:
            import Vision
            from Foundation import NSURL
            cleanup = screenshot_path is None
            if screenshot_path is None:
                screenshot_path = '/tmp/frida_screen_dump.png'
                screenshot(screenshot_path)
            url = NSURL.fileURLWithPath_(screenshot_path)
            handler = Vision.VNImageRequestHandler.alloc().initWithURL_options_(url, {})
            request = Vision.VNRecognizeTextRequest.alloc().init()
            request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
            handler.performRequests_error_([request], None)
            for obs in (request.results() or []):
                top = obs.topCandidates_(1)
                if not top:
                    continue
                label = top[0].string()
                if not label:
                    continue
                bbox = obs.boundingBox()
                cx = round((bbox.origin.x + bbox.size.width / 2) * SCREEN_W)
                cy = round((1.0 - (bbox.origin.y + bbox.size.height / 2)) * SCREEN_H)
                key = label.strip().lower()
                if key not in seen_labels:
                    seen_labels[key] = True
                    elements.append({"label": label, "x": cx, "y": cy,
                                     "w": 0, "h": 0, "source": "ocr"})
            if cleanup:
                try: os.remove(screenshot_path)
                except OSError: pass
        except ImportError:
            pass

    return elements


def dump_ocr(screenshot_path=None):
    """Take a screenshot and return all visible text with positions via OCR.

    Much faster than dump_elements — no Frida attach, just one screenshot + Vision.
    Returns list of dicts with 'text', 'x', 'y', 'w', 'h', 'confidence'.
    """
    try:
        import Vision
        from Foundation import NSURL
    except ImportError:
        print("[dump_ocr] Vision framework not available", file=sys.stderr)
        return []

    cleanup = screenshot_path is None
    if screenshot_path is None:
        screenshot_path = '/tmp/frida_screen_ocr.png'
        screenshot(screenshot_path)

    results = []
    try:
        url = NSURL.fileURLWithPath_(screenshot_path)
        handler = Vision.VNImageRequestHandler.alloc().initWithURL_options_(url, {})
        request = Vision.VNRecognizeTextRequest.alloc().init()
        request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
        handler.performRequests_error_([request], None)
        for obs in (request.results() or []):
            top = obs.topCandidates_(1)
            if not top:
                continue
            text = str(top[0].string())
            if not text.strip():
                continue
            conf = float(top[0].confidence())
            bbox = obs.boundingBox()
            x = round((bbox.origin.x + bbox.size.width / 2) * SCREEN_W)
            y = round((1.0 - (bbox.origin.y + bbox.size.height / 2)) * SCREEN_H)
            w = round(bbox.size.width * SCREEN_W)
            h = round(bbox.size.height * SCREEN_H)
            results.append({"text": text, "x": x, "y": y, "w": w, "h": h, "confidence": conf})
    finally:
        if cleanup:
            try: os.remove(screenshot_path)
            except OSError: pass

    return results


def tap_label(label, screenshot_path=None):
    """Find a UI element by label (case-insensitive) and tap it.

    Searches accessibility tree first; falls back to OCR.
    Returns True on success.
    """
    target = label.strip().lower()
    elements = dump_elements()

    # Exact match first, then partial
    match = None
    for el in elements:
        if el["label"].strip().lower() == target:
            match = el
            break
    if match is None:
        for el in elements:
            if target in el["label"].strip().lower():
                match = el
                break

    if match:
        x, y = match["x"], match["y"]
        print(f"[device] '{label}' → ({x}, {y}) [{match['source']}]")
        return tap(x, y)

    print(f"[device] label not found: '{label}'", file=sys.stderr)
    return False


def disconnect():
    global _tap_session, _tap_script, _ss_session, _ss_script, _tunnel_proc
    for script, session in [(_tap_script, _tap_session), (_ss_script, _ss_session)]:
        if script:
            try: script.unload()
            except: pass
        if session:
            try: session.detach()
            except: pass
    _tap_script = _tap_session = _ss_script = _ss_session = None
    if _tunnel_proc:
        _tunnel_proc.terminate()
        _tunnel_proc = None


_HELP = """
device.py — vphone-cli iOS VM automation

USAGE
  python3 device.py [--udid UDID] COMMAND [args...]

  --udid UDID         Target device UUID (overrides $VPHONE_UDID env var and default)
  --ssh-port PORT     SSH port for frida tunnel fallback (overrides $VPHONE_SSH_PORT, default 2231)

COMMANDS
  tap X Y               Tap at iOS logical coordinates (430×932 space)
  tap 'some text'       Find text on screen via OCR and tap it
  tap_label 'label'     Find UI element by accessibility label and tap it
  dump_elements         List all visible UI elements with positions (accessibility + OCR)
  swipe PRESET          Scroll/swipe using a named preset (see below)
  swipe X1 Y1 X2 Y2    Swipe from one point to another
  home                  Press the Home button
  launch_app BUNDLE_ID  Launch an app by bundle ID
  close_app BUNDLE_ID   Terminate an app by bundle ID
  screenshot [path]     Save a screenshot (default: screenshot.png)
  help                  Show this message

SWIPE PRESETS
  down        Scroll down (medium)
  down_long   Scroll down (large)
  down_short  Scroll down (small)
  up          Scroll up (medium)
  up_long     Scroll up (large)
  up_short    Scroll up (small)
  right       Swipe right / back gesture
  right_short Swipe right (short)
  left        Swipe left
  left_short  Swipe left (short)

EXAMPLES
  python3 device.py tap 'Settings'
  python3 device.py tap_label 'Back'
  python3 device.py tap_label 'Safari'
  python3 device.py tap_label 'Wi-Fi'
  python3 device.py swipe down
  python3 device.py swipe up_long
  python3 device.py home
  python3 device.py launch_app com.apple.mobilesafari
  python3 device.py close_app com.apple.mobilesafari
  python3 device.py screenshot screen.png
"""

if __name__ == "__main__":
    args = sys.argv[1:]
    while args and args[0].startswith("--"):
        if args[0] == "--udid":
            if len(args) < 2:
                print("error: --udid requires a value", file=sys.stderr)
                sys.exit(1)
            UDID = args[1]; args = args[2:]
        elif args[0] == "--ssh-port":
            if len(args) < 2:
                print("error: --ssh-port requires a value", file=sys.stderr)
                sys.exit(1)
            SSH_PORT = int(args[1]); args = args[2:]
        else:
            break
    if not args or args[0] in ("help", "--help", "-h"):
        print(_HELP)
        sys.exit(0)

    cmd = args[0]
    if cmd == "tap" and len(args) == 3:
        try:
            result = tap(int(args[1]), int(args[2]))
        except ValueError:
            result = tap(float(args[1]), float(args[2]))
        print(f"tap result: {result}")
    elif cmd == "dump_elements":
        elements = dump_elements()
        print(f"{'LABEL':<45} {'X':>5} {'Y':>5}  SOURCE")
        print("-" * 70)
        for el in sorted(elements, key=lambda e: (e['y'], e['x'])):
            print(f"{el['label']:<45} {el['x']:>5} {el['y']:>5}  {el['source']}")
        print(f"\n{len(elements)} elements found")
    elif cmd == "dump_ocr":
        results = dump_ocr()
        print(f"{'TEXT':<45} {'X':>5} {'Y':>5}  CONF")
        print("-" * 65)
        for r in sorted(results, key=lambda e: (e['y'], e['x'])):
            print(f"{r['text']:<45} {r['x']:>5} {r['y']:>5}  {r['confidence']:.2f}")
        print(f"\n{len(results)} text regions found")
    elif cmd == "tap_label" and len(args) == 2:
        result = tap_label(args[1])
        print(f"tap result: {result}")
    elif cmd == "tap" and len(args) == 2:
        result = tap_text(args[1])
        print(f"tap result: {result}")
    elif cmd == "swipe" and len(args) == 2:
        result = swipe(args[1])
        print(f"swipe result: {result}")
    elif cmd == "swipe" and len(args) == 5:
        result = swipe(int(args[1]), int(args[2]), int(args[3]), int(args[4]))
        print(f"swipe result: {result}")
    elif cmd == "home":
        result = home()
        print(f"home result: {result}")
    elif cmd == "launch_app" and len(args) == 2:
        launch_app(args[1])
    elif cmd == "close_app" and len(args) == 2:
        close_app(args[1])
    elif cmd == "screenshot":
        path = args[1] if len(args) > 1 else "screenshot.png"
        screenshot(path)
        print(f"screenshot saved: {path}")
    else:
        print(f"Unknown command: '{cmd}'. Run 'python3 device.py help' for usage.")
        sys.exit(1)

    disconnect()
