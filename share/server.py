#!/usr/bin/env python3
"""ScreenMirror: LAN JPEG stream for smart-TV browsers."""

from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST = "0.0.0.0"
PORTS = [int(p) for p in os.environ.get("MIRROR_PORTS", "8080,8000,8090").split(",") if p]
WIDTH = os.environ.get("MIRROR_WIDTH", "1920")
HEIGHT = os.environ.get("MIRROR_HEIGHT", "1080")
FPS = os.environ.get("MIRROR_FPS", "20")
# Lower qscale is sharper and heavier. 5 stays readable and encodes faster than 3.
QSCALE = os.environ.get("MIRROR_QSCALE", "5")

def _runtime_dir() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR") or str(Path.home() / ".cache")
    return Path(base) / "screenmirror"


RUNTIME = _runtime_dir()
FIFO = RUNTIME / "live.mjpg"
ACCESS_LOG = RUNTIME / "access.log"
URL_FILE = RUNTIME / "url"
STATUS_FILE = RUNTIME / "status.json"

# One long request. The browser paints each JPEG as it arrives, so the TV
# does not open a new connection or wait between pictures.
HTML = """<html>
<head>
<title>ScreenMirror</title>
<style type="text/css">
html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
img { position: absolute; left: 0; top: 0; width: 100%; height: 100%; border: 0; }
</style>
</head>
<body bgcolor="#000000">
<img src="stream.mjpg" alt="">
</body>
</html>
"""

# Older TV browsers that ignore a multipart stream can open /poll instead.
POLL_HTML = """<html>
<head>
<title>ScreenMirror</title>
<style type="text/css">
html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
#a, #b { position: absolute; left: 0; top: 0; width: 100%; height: 100%; border: 0; }
#b { display: none; }
</style>
</head>
<body bgcolor="#000000">
<img id="a" src="frame.jpg">
<img id="b">
<script type="text/javascript">
var a = document.getElementById('a');
var b = document.getElementById('b');
var showA = true;
function tick() {
  var next = showA ? b : a;
  var cur = showA ? a : b;
  next.onload = function() {
    next.style.display = 'block';
    cur.style.display = 'none';
    showA = !showA;
    tick();
  };
  next.onerror = function() { setTimeout(tick, 200); };
  next.src = 'frame.jpg?n=' + (new Date()).getTime();
}
tick();
</script>
</body>
</html>
"""

_lock = threading.Lock()
_cond = threading.Condition(_lock)
_frame = b""
_frame_id = 0
_status_ip = ""
_status_output = ""
_listening = False
_status_lock = threading.Lock()
_stop = threading.Event()
_proc: subprocess.Popen | None = None
_servers: list[ThreadingHTTPServer] = []


def lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("1.1.1.1", 80))
        return s.getsockname()[0]
    finally:
        s.close()


def default_output() -> str:
    env = os.environ.get("MIRROR_OUTPUT")
    if env:
        return env
    try:
        mons = json.loads(subprocess.check_output(["hyprctl", "monitors", "-j"], text=True))
        for mon in mons:
            if mon.get("focused"):
                return mon["name"]
        if mons:
            return mons[0]["name"]
    except Exception:
        pass
    return "eDP-1"


def output_size(output: str) -> tuple[int, int] | None:
    try:
        mons = json.loads(subprocess.check_output(["hyprctl", "monitors", "-j"], text=True))
    except Exception:
        return None
    for mon in mons:
        if mon.get("name") == output:
            return int(mon["width"]), int(mon["height"])
    return None


def start_capture(output: str) -> subprocess.Popen:
    if FIFO.exists() or FIFO.is_symlink():
        FIFO.unlink()
    os.mkfifo(FIFO, 0o600)
    log = open(RUNTIME / "capture.log", "w")
    cmd = [
        "wf-recorder",
        "-o",
        output,
        "-c",
        "mjpeg",
        "-r",
        FPS,
        "-x",
        "yuvj420p",
        "-p",
        f"qscale={QSCALE}",
        "-p",
        "qmin=3",
        "-p",
        "qmax=8",
        "-m",
        "mjpeg",
        "-f",
        str(FIFO),
        "-D",
    ]
    native = output_size(output)
    target = (int(WIDTH), int(HEIGHT))
    if native != target:
        # fast_bilinear is much cheaper than lanczos. The panel is already 1080p,
        # so this filter is skipped in the normal case.
        cmd[cmd.index("-m"):cmd.index("-m")] = [
            "-F",
            f"scale={WIDTH}:{HEIGHT}:flags=fast_bilinear",
        ]
    rec = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=log,
        env=os.environ.copy(),
    )
    return rec


def reader_loop(proc: subprocess.Popen) -> None:
    global _frame, _frame_id
    fh = open(FIFO, "rb")
    buf = b""
    try:
        while not _stop.is_set():
            chunk = fh.read(65536)
            if not chunk:
                if proc.poll() is not None:
                    break
                time.sleep(0.01)
                continue
            buf += chunk
            if len(buf) > 8_000_000:
                buf = buf[-2_000_000:]
            while True:
                start = buf.find(b"\xff\xd8")
                if start < 0:
                    buf = buf[-1:]
                    break
                end = buf.find(b"\xff\xd9", start + 2)
                if end < 0:
                    buf = buf[start:]
                    break
                jpeg = buf[start : end + 2]
                buf = buf[end + 2 :]
                with _cond:
                    _frame = jpeg
                    _frame_id += 1
                    first = _frame_id == 1
                    _cond.notify_all()
                if first and _status_ip:
                    write_status(_status_ip, _status_output, _listening, ready=True)
    finally:
        fh.close()
    _stop.set()


def log_access(addr: str, line: str) -> None:
    stamp = time.strftime("%H:%M:%S")
    msg = f"{stamp} {addr} {line}\n"
    sys.stderr.write(msg)
    sys.stderr.flush()
    with ACCESS_LOG.open("a") as fh:
        fh.write(msg)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    close_connection = True

    def log_message(self, fmt: str, *args) -> None:
        log_access(self.address_string(), fmt % args)

    def _send(self, code: int, ctype: str, body: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html", "/index.htm"):
            self._send(200, "text/html", HTML.encode("ascii", "replace"))
            return
        if path == "/poll":
            self._send(200, "text/html", POLL_HTML.encode("ascii", "replace"))
            return
        if path in ("/stream.mjpg", "/live.mjpg"):
            self._stream()
            return
        if path in ("/frame.jpg", "/frame.jpeg", "/desktop.jpg"):
            with _lock:
                frame = _frame
            if not frame:
                self._send(503, "text/plain", b"starting\n")
                return
            self._send(200, "image/jpeg", frame)
            return
        if path in ("/health", "/ok"):
            body = b"ok\n" if _frame_id else b"starting\n"
            self._send(200 if _frame_id else 503, "text/plain", body)
            return
        self._send(404, "text/plain", b"not found\n")

    def _stream(self) -> None:
        """Push the newest JPEG as soon as it is encoded. Skip any the TV has not caught up to."""
        try:
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        last = 0
        try:
            while not _stop.is_set():
                with _cond:
                    if _frame_id == last:
                        _cond.wait(timeout=0.5)
                    frame = _frame
                    fid = _frame_id
                if not frame or fid == last:
                    continue
                last = fid
                packet = (
                    b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: "
                    + str(len(frame)).encode()
                    + b"\r\n\r\n"
                    + frame
                    + b"\r\n"
                )
                self.wfile.write(packet)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError):
            return


def write_status(ip: str, output: str, listening: bool, ready: bool | None = None) -> None:
    urls = [f"http://{ip}:{port}/" for port in PORTS]
    if ready is None:
        ready = _frame_id > 0
    payload = (
        json.dumps(
            {
                "listening": listening,
                "ready": ready,
                "ip": ip,
                "output": output,
                "urls": urls,
                "primary": urls[0],
            },
            indent=2,
        )
        + "\n"
    )
    with _status_lock:
        URL_FILE.write_text(urls[0] + "\n")
        STATUS_FILE.write_text(payload)


def main() -> int:
    global _proc, _status_ip, _status_output, _listening
    RUNTIME.mkdir(mode=0o700, exist_ok=True)
    ACCESS_LOG.touch()
    ip = lan_ip()
    output = default_output()
    _status_ip = ip
    _status_output = output
    write_status(ip, output, False, ready=False)

    _proc = start_capture(output)
    threading.Thread(target=reader_loop, args=(_proc,), daemon=True).start()

    deadline = time.time() + 8
    while time.time() < deadline and _frame_id == 0 and not _stop.is_set():
        time.sleep(0.1)

    for port in PORTS:
        httpd = ThreadingHTTPServer((HOST, port), Handler)
        httpd.daemon_threads = True
        _servers.append(httpd)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        print(f"Listening on http://{ip}:{port}/", flush=True)

    _listening = True
    write_status(ip, output, True)
    print(f"Primary URL: http://{ip}:{PORTS[0]}/", flush=True)

    def shutdown(*_args) -> None:
        _stop.set()
        for httpd in _servers:
            httpd.shutdown()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    try:
        while not _stop.is_set():
            time.sleep(0.5)
    finally:
        _stop.set()
        if _proc and _proc.poll() is None:
            _proc.send_signal(signal.SIGINT)
            time.sleep(0.4)
        if _proc and _proc.poll() is None:
            _proc.kill()
        for httpd in _servers:
            httpd.server_close()
        for path in (URL_FILE, STATUS_FILE, FIFO):
            try:
                path.unlink()
            except FileNotFoundError:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
