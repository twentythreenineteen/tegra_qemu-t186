import socket
import struct
import os
import sys
import array
import zlib
import time
import json

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uinput_touch import VirtualTouchscreen
from actions import ACTIONS

# ============================================================
# Wayland protocol client (from your cleaned-up hscreen_capture.py)
# ============================================================

def pad4(n):
    return (n + 3) & ~3

class Wayland_Socket:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.next_id = 2  # 1 is wl_display
        self.recv_buf = b""
        self.fd_queue = []  # fds received out-of-band, consumed in order
        
        print(f"[+] Connecting to Wayland socket at path = {path}")

    def new_id(self):
        i = self.next_id
        self.next_id += 1
        return i

    def send_message(self, obj_id, opcode, arg_bytes):
        size = 8 + len(arg_bytes)
        header = struct.pack("<IHH", obj_id, opcode, size)
        self.sock.sendmsg([header + arg_bytes])

    @staticmethod
    def pack_uint(v):
        return struct.pack("<I", v)

    @staticmethod
    def pack_string(s):
        b = s.encode() + b"\x00"
        padded_len = pad4(len(b))
        return struct.pack("<I", len(b)) + b + b"\x00" * (padded_len - len(b))

    def _fill(self, n):
        while len(self.recv_buf) < n:
            fds = array.array("i")
            cmsg_space = socket.CMSG_SPACE(64 * fds.itemsize)
            data, ancdata, flags, addr = self.sock.recvmsg(4096, cmsg_space)
            
            if not data:
                raise ConnectionError("Wayland socket closed")
            
            self.recv_buf += data
            for cmsg_level, cmsg_type, cmsg_data in ancdata:
                if cmsg_level == socket.SOL_SOCKET and cmsg_type == socket.SCM_RIGHTS:
                    got = array.array("i")
                    got.frombytes(cmsg_data[: len(cmsg_data) - (len(cmsg_data) % got.itemsize)])
                    self.fd_queue.extend(got)

    def read_message(self):
        self._fill(8)
        obj_id, opcode, size = struct.unpack("<IHH", self.recv_buf[:8])
        self._fill(size)
        arg_bytes = self.recv_buf[8:size]
        self.recv_buf = self.recv_buf[size:]
        return obj_id, opcode, arg_bytes

    def pop_fd(self):
        if not self.fd_queue:
            raise RuntimeError("Expected an fd but none received yet")
        return self.fd_queue.pop(0)

def parse_string(buf, off):
    (length,) = struct.unpack_from("<I", buf, off)
    off += 4
    s = buf[off : off + length - 1].decode(errors="replace")
    off += pad4(length)
    return s, off

def read_frame_bytes(fd, width, height):
    """mmap the fd, copy out the raw RGBA bytes, close the fd, return bytes."""
    import mmap

    st = os.fstat(fd)
    size = st.st_size if st.st_size > 0 else width * height * 4
    buf = mmap.mmap(fd, size, prot=mmap.PROT_READ)
    data = buf[:]
    buf.close()
    os.close(fd)
    return data

# ============================================================
# Persistent connection: do the registry/bind/getHScreen handshake ONCE,
# then just call hscreen.capture() repeatedly on the same live object.
# This removes most of the per-frame round trips that made things slow.
# ============================================================
import threading

class Screen:
    def __init__(self):
        self.sock_path = "/run/wayland-system"
        self.screen_type = 8
        self.lock = threading.Lock()
        self.conn = None
        self.hscreen_id = None 
        
        print(f"[+] Setting up HScreen connection")
        print(f"[+] Screen Type = 8 (FRONT_CENTER)")
        
        self._connect_and_setup()

    def _connect_and_setup(self):
        DISPLAY_ID = 1
        conn = Wayland_Socket(self.sock_path)
        conn.sock.settimeout(5.0)

        registry_id = conn.new_id()
        sync_id = conn.new_id()
        conn.send_message(DISPLAY_ID, 1, conn.pack_uint(registry_id))
        conn.send_message(DISPLAY_ID, 0, conn.pack_uint(sync_id))

        wm_global_name = None
        wm_version = None
        sync_done = False
        
        while not sync_done:
            obj_id, opcode, args = conn.read_message()
            if obj_id == DISPLAY_ID and opcode == 0:
                _, err_code = struct.unpack_from("<II", args, 0)
                msg, _ = parse_string(args, 8)
                raise RuntimeError(f"wl_display error during setup: {msg}")
            if obj_id == registry_id and opcode == 0:
                name, off = struct.unpack_from("<I", args, 0)[0], 4
                iface, off = parse_string(args, off)
                version = struct.unpack_from("<I", args, off)[0]
                if iface == "ccos_wm":
                    wm_global_name, wm_version = name, version
                continue
            if obj_id == sync_id and opcode == 0:
                sync_done = True

        if wm_global_name is None:
            raise RuntimeError("ccos_wm global not found")

        wm_id = conn.new_id()
        hscreen_id = conn.new_id()
        check_sync = conn.new_id()
        
        conn.send_message(registry_id, 0, conn.pack_uint(wm_global_name) + conn.pack_string("ccos_wm") + conn.pack_uint(wm_version) + conn.pack_uint(wm_id))
        conn.send_message(wm_id, 3, conn.pack_uint(self.screen_type) + conn.pack_uint(hscreen_id))
        conn.send_message(DISPLAY_ID, 0, conn.pack_uint(check_sync))
        
        while True:
            obj_id, opcode, args = conn.read_message()
            if obj_id == DISPLAY_ID and opcode == 0:
                _, err_code = struct.unpack_from("<II", args, 0)
                msg, _ = parse_string(args, 8)
                raise RuntimeError(f"wl_display error after getHScreen: {msg}")
            if obj_id == check_sync and opcode == 0:
                break

        self.conn = conn
        self.hscreen_id = hscreen_id

    def capture_once(self):
        """Fire hscreen.capture() and wait for onResult. Reconnects and
        retries once automatically if the connection has gone bad."""
        t_wait0 = time.time()
        with self.lock:
            t_wait1 = time.time()
            lock_wait_ms = (t_wait1 - t_wait0) * 1000
            if lock_wait_ms > 5:
                print(f"    [lock] waited {lock_wait_ms:.0f}ms for capture lock "
                      f"(another request was in flight)")
            try:
                return self._capture_locked()
            except (ConnectionError, OSError, socket.timeout) as e:
                print(f"[!] capture failed ({e!r}), reconnecting...")
                self._connect_and_setup()
                return self._capture_locked()

    def _capture_locked(self):
        DISPLAY_ID = 1
        hcapture_id = self.conn.new_id()
        self.conn.send_message(self.hscreen_id, 1, self.conn.pack_uint(hcapture_id))
        while True:
            obj_id, opcode, args = self.conn.read_message()
            if obj_id == DISPLAY_ID and opcode == 0:
                _, err_code = struct.unpack_from("<II", args, 0)
                msg, _ = parse_string(args, 8)
                raise RuntimeError(f"wl_display error during capture: {msg}")
            if obj_id == hcapture_id and opcode == 0:
                result, width, height = struct.unpack_from("<iII", args, 0)
                fd = self.conn.pop_fd()
                return result, width, height, fd

_screen = None  # initialized in main()
_touch = None   # initialized in main()
_touch_lock = threading.Lock()

# Caches the last frame's hash + encoded PNG per (screen_type, downscale)
# combo, so unchanged frames skip PNG encoding and transfer entirely.
_frame_cache = {}
_frame_cache_lock = threading.Lock()

# Full native capture resolution - used both to size the virtual touchscreen
# and so the browser can translate a click on a (possibly downscaled)
# displayed image back into real screen coordinates.
FULL_WIDTH = 1920
FULL_HEIGHT = 720

def do_tap(x, y):
    global _touch
    with _touch_lock:
        if _touch is None:
            _touch = VirtualTouchscreen(FULL_WIDTH, FULL_HEIGHT)
        _touch.tap(x, y)

def do_swipe(points, duration):
    global _touch
    with _touch_lock:
        if _touch is None:
            _touch = VirtualTouchscreen(FULL_WIDTH, FULL_HEIGHT)
        _touch.swipe(points, duration=duration)

# ============================================================
# Minimal from-scratch PNG encoder
# ============================================================

def _png_chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

def rgba_to_png(rgba_bytes, width, height):
    """Encode raw, tightly-packed RGBA8888 bytes as a PNG (color type 6,
    8-bit depth, filter type 0/None per scanline)."""
    sig = b"\x89PNG\r\n\x1a\n"
    
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    
    stride = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type: None
        raw += rgba_bytes[y * stride : (y + 1) * stride]
    idat = zlib.compress(bytes(raw), level = 1)
    
    return (sig + _png_chunk(b"IHDR", ihdr) + _png_chunk(b"IDAT", idat) + _png_chunk(b"IEND", b""))

def downscale_rgba(rgba_bytes, width, height, factor):
    """Fast nearest-neighbor downscale by an integer factor, using
    memoryview.cast to treat pixels as 32-bit units so the row/column
    striding happens in C, not a per-pixel Python loop."""
    if factor <= 1:
        return rgba_bytes, width, height
    
    new_w = width // factor
    new_h = height // factor
    src = memoryview(rgba_bytes).cast("I")
    out = bytearray(new_w * new_h * 4)
    dst = memoryview(out).cast("I")
    
    for y in range(new_h):
        src_row_start = (y * factor) * width
        dst[y * new_w : (y + 1) * new_w] = src[src_row_start : src_row_start + width : factor]
    
    return bytes(out), new_w, new_h


def capture_frame_raw(screen_type = 8, downscale = 1):
    global _screen
    
    t0 = time.time()
    out = _screen.capture_once()
    t1 = time.time()
    if out is None:
        return None
    result, width, height, fd = out
    if result != 0:
        os.close(fd)
        return None
    
    data = read_frame_bytes(fd, width, height)
    t2 = time.time()
    
    data, width, height = downscale_rgba(data, width, height, downscale)
    t2b = time.time()
    
    timings = {
        "capture_ms": (t1 - t0) * 1000,
        "mmap_copy_ms": (t2 - t1) * 1000,
        "downscale_ms": (t2b - t2) * 1000,
    }
    return data, width, height, timings


def capture_frame_png(screen_type = 8, downscale = 1):
    out = capture_frame_raw(screen_type=screen_type, downscale=downscale)
    if out is None:
        return None
    data, width, height, timings = out

    t2b = time.time()
    png_bytes = rgba_to_png(data, width, height)
    t3 = time.time()

    timings = dict(timings)
    timings["png_encode_ms"] = (t3 - t2b) * 1000
    timings["total_ms"] = sum(
        v for k, v in timings.items() if k != "total_ms"
    )
    return png_bytes, width, height, timings


# ============================================================
# HTTP server
# ============================================================

INDEX_HTML = """<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Live screen</title>
  <style>
    body { margin: 0; background: #111; display: flex; align-items: center;
           justify-content: center; height: 100vh; }
    #wrap { position: relative; display: inline-block; max-width: 100%; max-height: 100%; }
    img { display: block; max-width: 100%; max-height: 100%; cursor: crosshair;
          touch-action: none; -webkit-user-drag: none; user-select: none; }
    #crosshair {
      position: absolute; width: 20px; height: 20px; pointer-events: none;
      transform: translate(-50%, -50%); display: none;
    }
    #crosshair::before, #crosshair::after {
      content: ""; position: absolute; background: red;
    }
    #crosshair::before { left: 9px; top: 0; width: 2px; height: 20px; }
    #crosshair::after  { top: 9px; left: 0; width: 20px; height: 2px; }
    #coords {
      position: absolute; top: 8px; left: 8px; color: #0f0;
      font: 12px monospace; background: rgba(0,0,0,0.6); padding: 2px 6px;
      pointer-events: none;
    }
    #toolbar {
      position: absolute; top: 8px; right: 8px; display: flex; gap: 6px;
    }
    #toolbar button {
      font: 12px sans-serif; padding: 6px 10px; background: #333; color: #eee;
      border: 1px solid #555; border-radius: 4px; cursor: pointer;
    }
    #toolbar button:hover { background: #444; }
    #toolbar button:active { background: #222; }
    #action-status {
      position: absolute; bottom: 8px; left: 8px; color: #0f0;
      font: 12px monospace; background: rgba(0,0,0,0.6); padding: 2px 6px;
      pointer-events: none; display: none;
    }
  </style>
</head>
<body>
  <div id="wrap">
    <img id="f" src="/frame.png">
    <div id="crosshair"></div>
    <div id="coords"></div>
    <div id="toolbar">__ACTION_BUTTONS__</div>
    <div id="action-status"></div>
  </div>
  <script>
    const FULL_W = __FULL_WIDTH__;
    const FULL_H = __FULL_HEIGHT__;
    const img = document.getElementById('f');
    const crosshair = document.getElementById('crosshair');
    const coords = document.getElementById('coords');

    let lastObjectUrl = null;

    async function refresh() {
      try {
        const res = await fetch("/frame.png?t=" + Date.now(), {cache: "no-store"});
        if (res.status === 200) {
          const blob = await res.blob();
          const url = URL.createObjectURL(blob);
          const oldUrl = lastObjectUrl;
          img.onload = () => { if (oldUrl) URL.revokeObjectURL(oldUrl); };
          img.src = url;
          lastObjectUrl = url;
        }
        // 204 = unchanged since last frame - nothing to do, just poll again
        refresh();
      } catch (e) {
        setTimeout(refresh, 500);
      }
    }
    refresh();

    let dragging = false, path = [], startTime = 0;

    img.addEventListener('pointerdown', (e) => {
      img.setPointerCapture(e.pointerId);
      dragging = true;
      path = [translate(e)];
      startTime = performance.now();
      showCrosshair(e);
    });

    img.addEventListener('pointermove', (e) => {
      if (!dragging) return;
      const pt = translate(e);
      const last = path[path.length - 1];
      // only keep a new sample if it moved a meaningful amount, to avoid
      // sending huge point arrays for a slow drag
      const dx = pt[0] - last[0], dy = pt[1] - last[1];
      if (Math.hypot(dx, dy) > 4) path.push(pt);
      showCrosshair(e);
    });

    img.addEventListener('pointerup', (e) => {
      if (!dragging) return;
      dragging = false;
      const endPt = translate(e);
      const last = path[path.length - 1];
      const totalDx = endPt[0] - path[0][0], totalDy = endPt[1] - path[0][1];
      const totalDist = Math.hypot(totalDx, totalDy);
      const duration = Math.max(0.05, (performance.now() - startTime) / 1000);

      if (totalDist < 10) {
        // small movement -> treat as a plain tap
        fetch(`/tap?x=${path[0][0].toFixed(1)}&y=${path[0][1].toFixed(1)}`);
        coords.textContent = `tap: (${path[0][0].toFixed(0)}, ${path[0][1].toFixed(0)})`;
      } else {
        path.push(endPt);
        fetch('/swipe', {
          method: 'POST',
          headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({points: path, duration: duration}),
        });
        coords.textContent = `swipe: ${path.length} pts, ${duration.toFixed(2)}s`;
      }
    });

    function translate(e) {
      const rect = img.getBoundingClientRect();
      const dx = e.clientX - rect.left;
      const dy = e.clientY - rect.top;
      return [(dx / rect.width) * FULL_W, (dy / rect.height) * FULL_H];
    }

    function showCrosshair(e) {
      const rect = img.getBoundingClientRect();
      crosshair.style.left = (e.clientX - rect.left) + "px";
      crosshair.style.top = (e.clientY - rect.top) + "px";
      crosshair.style.display = "block";
    }

    const actionStatus = document.getElementById('action-status');
    async function doAction(id) {
      actionStatus.style.display = "block";
      actionStatus.textContent = `running ${id}...`;
      try {
        const res = await fetch(`/action?id=${encodeURIComponent(id)}`);
        const text = await res.text();
        actionStatus.textContent = res.ok ? `${id}: ${text}` : `${id} FAILED: ${text}`;
      } catch (e) {
        actionStatus.textContent = `${id} FAILED: ${e}`;
      }
      setTimeout(() => { actionStatus.style.display = "none"; }, 3000);
    }
  </script>
</body>
</html>
"""

class Handler(BaseHTTPRequestHandler):
    screen_type = 8  # overridden by main() below
    default_scale = 1  # overridden by main() below via ?scale=N or CLI arg

    def log_message(self, fmt, *args):
        # keep default console noise down; comment this out if you want logs
        pass

    def _parse_qs(self):
        qs = {}
        if "?" in self.path:
            for kv in self.path.split("?", 1)[1].split("&"):
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    qs[k] = v
        return qs

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            buttons_html = "".join(
                f'<button onclick="doAction(\'{a["id"]}\')">{a["label"]}</button>'
                for a in ACTIONS
            )
            html = INDEX_HTML.replace("__FULL_WIDTH__", str(FULL_WIDTH)).replace(
                "__FULL_HEIGHT__", str(FULL_HEIGHT)
            ).replace("__ACTION_BUTTONS__", buttons_html)
            body = html.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if path == "/action":
            qs = self._parse_qs()
            action_id = qs.get("id")
            action = next((a for a in ACTIONS if a["id"] == action_id), None)
            if action is None:
                self.send_response(404)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(f"unknown action: {action_id}".encode())
                return

            try:
                result = action["fn"]()
                body = str(result if result is not None else "ok").encode()
                print(f"[action] {action_id}: {body.decode()}")
                self.send_response(200)
            except Exception as e:
                body = f"{type(e).__name__}: {e}".encode()
                print(f"[action] {action_id} FAILED: {body.decode()}")
                self.send_response(500)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if path == "/tap":
            qs = self._parse_qs()
            try:
                x, y = float(qs["x"]), float(qs["y"])
            except (KeyError, ValueError):
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"need numeric x= and y=")
                return
            t0 = time.time()
            do_tap(x, y)
            elapsed = (time.time() - t0) * 1000
            print(f"[tap] ({x:.0f},{y:.0f})  {elapsed:.0f}ms")
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if path == "/frame.png":
            t_start = time.time()

            qs = self._parse_qs()
            downscale = int(qs.get("scale", self.default_scale))

            out = capture_frame_raw(screen_type=self.screen_type, downscale = downscale)
            if out is None:
                self.send_response(503)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(b"capture failed")
                return
            data, w, h, timings = out

            t_hash0 = time.time()
            frame_hash = zlib.crc32(data) & 0xFFFFFFFF
            t_hash1 = time.time()

            cache_key = (self.screen_type, downscale)
            with _frame_cache_lock:
                cached = _frame_cache.get(cache_key)
                unchanged = cached is not None and cached[0] == frame_hash

            if unchanged:
                self.send_response(204)
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                # no print here on purpose - this path fires many times per
                # second while the screen is idle and would flood the console
                return

            png_bytes = rgba_to_png(data, w, h)
            with _frame_cache_lock:
                _frame_cache[cache_key] = (frame_hash, png_bytes)

            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(png_bytes)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()

            t_send0 = time.time()
            self.wfile.write(png_bytes)
            t_send1 = time.time()

            print(
                f"[frame] size = {len(png_bytes)/1024:.0f}KB "
                f"capture = {timings['capture_ms']:.0f}ms "
                f"hash = {(t_hash1-t_hash0)*1000:.0f}ms "
                f"mmap = {timings['mmap_copy_ms']:.0f}ms "
                f"downscale = {timings['downscale_ms']:.0f}ms "
                f"encode = {(t_send0-t_hash1)*1000:.0f}ms "
                f"transmit = {(t_send1-t_send0)*1000:.0f}ms "
                f"TOTAL = {(t_send1-t_start)*1000:.0f}ms/frame"
            )
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path == "/swipe":
            length = int(self.headers.get("Content-Length", 0))
            try:
                payload = json.loads(self.rfile.read(length))
                points = [(float(p[0]), float(p[1])) for p in payload["points"]]
                duration = float(payload.get("duration", 0.3))
                duration = max(0.05, min(3.0, duration))  # sane bounds
            except (ValueError, KeyError, TypeError, json.JSONDecodeError):
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"bad swipe payload")
                return

            t0 = time.time()
            do_swipe(points, duration)
            elapsed = (time.time() - t0) * 1000
            print(f"[swipe] {len(points)} points over {duration:.2f}s  {elapsed:.0f}ms")
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(404)
        self.end_headers()

def main():
    global _screen
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    scale = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    
    # 8 = FRONT_CENTER (Head Unit)
    SCREEN_TYPE = 8
    
    # Native capture resolution
    WIDTH = 1920
    HEIGHT = 720
    
    Handler.screen_type = SCREEN_TYPE
    Handler.default_scale = scale

    _screen = Screen()

    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"[+] Scaling set to {scale} ({WIDTH // scale}x{HEIGHT // scale})")
    print(f"[+] Serving on http://192.168.43.1:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass

if __name__ == "__main__":
    main()
