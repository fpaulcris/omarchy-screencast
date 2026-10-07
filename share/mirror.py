#!/usr/bin/env python3
"""Mirror the desktop to one Chromecast receiver.

The browser stream stays MJPEG. Chromecast plays an H.264 HLS copy of the
same screen, started only while a mirror is running.
"""

from __future__ import annotations

import json
import os
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

from castlib import CastSession
from discover import build, probe_dial

HERE = Path(__file__).resolve().parent
SERVER = HERE / "server.py"
PORTS = (8080, 8000, 8090)


def runtime_dir() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR") or str(Path.home() / ".cache")
    path = Path(base) / "screenmirror"
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    return path


RUNTIME = runtime_dir()
STATE = RUNTIME / "mirror.json"
LOG = RUNTIME / "mirror.log"


def lan_ip() -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("1.1.1.1", 80))
        return sock.getsockname()[0]
    finally:
        sock.close()


def read_state() -> dict:
    try:
        data = json.loads(STATE.read_text(encoding="utf-8"))
    except Exception:
        return {"state": "stopped", "id": "", "name": "", "detail": ""}
    return data if isinstance(data, dict) else {"state": "stopped", "id": "", "name": "", "detail": ""}


def write_state(data: dict) -> None:
    temporary = STATE.with_suffix(".tmp")
    temporary.write_text(json.dumps(data) + "\n", encoding="utf-8")
    os.replace(temporary, STATE)


def publish_hls_token() -> str:
    RUNTIME.mkdir(mode=0o700, parents=True, exist_ok=True)
    token = secrets.token_hex(16)
    path = RUNTIME / "hls.token"
    temporary = path.with_suffix(".tmp")
    temporary.write_text(token + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
    return token


def clear_hls_token() -> None:
    try:
        (RUNTIME / "hls.token").unlink()
    except OSError:
        pass


def pid_alive(pid: object) -> bool:
    try:
        number = int(pid)
    except (TypeError, ValueError):
        return False
    if number <= 0:
        return False
    try:
        os.kill(number, 0)
    except OSError:
        return False
    return True


def log(line: str) -> None:
    stamp = time.strftime("%H:%M:%S")
    with LOG.open("a", encoding="utf-8") as handle:
        handle.write(f"{stamp} {line}\n")


def kill_pid(pid: object) -> None:
    try:
        number = int(pid)
    except (TypeError, ValueError):
        return
    if number <= 0:
        return
    try:
        os.kill(number, signal.SIGTERM)
    except ProcessLookupError:
        return
    for _ in range(50):
        try:
            os.kill(number, 0)
        except ProcessLookupError:
            return
        time.sleep(0.1)
    try:
        os.kill(number, signal.SIGKILL)
    except ProcessLookupError:
        pass


def stream_ports() -> tuple[int, ...]:
    raw = os.environ.get("MIRROR_PORTS", "")
    if not raw.strip():
        return PORTS
    found = []
    for part in raw.split(","):
        try:
            found.append(int(part))
        except ValueError:
            continue
    return tuple(found) or PORTS


def port_open(port: int) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=0.4) as response:
            return response.status in (200, 503)
    except urllib.error.HTTPError as exc:
        return exc.code in (200, 503)
    except Exception:
        return False


def origin_port() -> int | None:
    for port in stream_ports():
        if port_open(port):
            return port
    return None


def output_size(name: str) -> tuple[int, int] | None:
    try:
        monitors = json.loads(subprocess.check_output(["hyprctl", "monitors", "-j"], text=True))
    except Exception:
        return None
    for monitor in monitors:
        if str(monitor.get("name")) == name:
            try:
                return int(monitor["width"]), int(monitor["height"])
            except (KeyError, TypeError, ValueError):
                return None
    return None


def capture_output() -> str:
    try:
        data = json.loads((RUNTIME / "status.json").read_text(encoding="utf-8"))
        if data.get("output"):
            return str(data["output"])
    except Exception:
        pass
    try:
        monitors = json.loads(subprocess.check_output(["hyprctl", "monitors", "-j"], text=True))
    except Exception:
        return ""
    for monitor in monitors:
        if monitor.get("focused"):
            return str(monitor.get("name") or "")
    if monitors:
        return str(monitors[0].get("name") or "")
    return ""


def h264_level(width: int, height: int) -> str:
    """SPS level that can actually carry this frame size."""
    blocks = ((width + 15) // 16) * ((height + 15) // 16)
    if width <= 1280 and height <= 720 and blocks <= 3600:
        return "3.1"
    if width <= 1920 and height <= 1088 and blocks <= 8192:
        return "4.0"
    if blocks <= 22080:
        return "5.0"
    return "5.1"


def desktop_monitor() -> str:
    """Pulse monitor of the sink that is actually playing, so the TV gets that sound."""
    try:
        sink = subprocess.check_output(["pactl", "get-default-sink"], text=True, timeout=2).strip()
    except Exception:
        return ""
    if not sink or any(char.isspace() for char in sink):
        return ""
    return f"{sink}.monitor"


def cast_size(model: str, output: str) -> tuple[int, int]:
    width, height = (1280, 720) if "hub" in model.lower() else (1920, 1080)
    path = Path.home() / ".config" / "screenmirror" / "cast.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("auto") is False:
            width = int(data.get("width") or width)
            height = int(data.get("height") or height)
    except Exception:
        pass
    native = output_size(output)
    if native and (width > native[0] or height > native[1]):
        width, height = native
    return width - (width % 2), height - (height % 2)


def browse() -> dict:
    try:
        proc = subprocess.run(
            ["avahi-browse", "-arpkt"],
            text=True,
            capture_output=True,
            timeout=6,
        )
        text = proc.stdout or ""
    except subprocess.TimeoutExpired as exc:
        text = exc.stdout or ""
        if isinstance(text, bytes):
            text = text.decode("utf-8", "replace")
    except FileNotFoundError as exc:
        raise RuntimeError("Install avahi to look for receivers.") from exc
    return build(text, probe_dial)


def find_receiver(device_id: str) -> dict:
    for item in browse().get("receivers") or []:
        if item.get("id") == device_id:
            return item
    raise RuntimeError(f"No receiver with id {device_id}.")


def start_server() -> int:
    log_path = RUNTIME / "server.log"
    handle = log_path.open("a", encoding="utf-8")
    proc = subprocess.Popen(
        [sys.executable, str(SERVER)],
        stdout=handle,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        env=os.environ.copy(),
    )
    deadline = time.time() + 12
    while time.time() < deadline:
        if origin_port() is not None:
            return proc.pid
        if proc.poll() is not None:
            raise RuntimeError("The stream server stopped.")
        time.sleep(0.2)
    kill_pid(proc.pid)
    raise RuntimeError("The stream server did not open a port.")


def start_encoder(output: str, width: int, height: int) -> tuple[subprocess.Popen, subprocess.Popen, Path]:
    if not output:
        raise RuntimeError("No screen to capture.")
    if shutil.which("wf-recorder") is None or shutil.which("ffmpeg") is None:
        raise RuntimeError("wf-recorder and ffmpeg are required to mirror.")
    hls = RUNTIME / "hls"
    if hls.exists():
        for child in hls.iterdir():
            if child.is_file():
                child.unlink()
    else:
        hls.mkdir(mode=0o700)
    fifo = RUNTIME / "cast.ts"
    if fifo.exists() or fifo.is_symlink():
        fifo.unlink()
    os.mkfifo(fifo, 0o600)
    native = output_size(output)
    recorder = [
        "wf-recorder",
        "-o",
        output,
        "-c",
        "libx264",
        "-x",
        "yuv420p",
        "-r",
        "15",
        "-p",
        "preset=ultrafast",
        "-p",
        "tune=zerolatency",
        "-p",
        "profile=baseline",
        "-p",
        "g=15",
        "-b",
        "0",
        "-D",
    ]
    if native and native != (width, height):
        recorder.extend(["-F", f"scale={width}:{height}:flags=bilinear"])
    recorder.extend(["-m", "mpegts", "-f", str(fifo)])
    encoder_log = (RUNTIME / "encoder.log").open("a", encoding="utf-8")
    monitor = desktop_monitor()
    if monitor:
        audio = ["-f", "pulse", "-ac", "2", "-i", monitor]
        log(f"audio {monitor}")
    else:
        audio = ["-f", "lavfi", "-i", "anullsrc=sample_rate=48000:channel_layout=stereo"]
        log("audio silence")
    ffmpeg = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "warning",
        "-fflags",
        "nobuffer",
        "-i",
        str(fifo),
        *audio,
        "-map",
        "0:v:0",
        "-map",
        "1:a:0",
        "-vf",
        "scale=in_range=pc:out_range=tv,format=yuv420p",
        "-c:v",
        "libx264",
        "-profile:v",
        "baseline",
        "-level",
        h264_level(width, height),
        "-preset",
        "ultrafast",
        "-tune",
        "zerolatency",
        "-g",
        "30",
        "-keyint_min",
        "30",
        "-sc_threshold",
        "0",
        "-bf",
        "0",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-ac",
        "2",
        "-ar",
        "48000",
        "-b:a",
        "128k",
        "-f",
        "hls",
        "-hls_time",
        "2",
        "-hls_list_size",
        "5",
        "-hls_flags",
        "delete_segments+append_list+omit_endlist+temp_file",
        "-hls_segment_type",
        "mpegts",
        "-hls_segment_filename",
        "seg_%05d.ts",
        "live.m3u8",
    ]
    # Open the reader first. wf-recorder blocks until ffmpeg opens the fifo.
    # The playlist must name segments relatively so the receiver requests /hls/seg_*.ts.
    ffmpeg_proc = subprocess.Popen(
        ffmpeg,
        cwd=hls,
        stdout=encoder_log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    recorder_proc = subprocess.Popen(
        recorder,
        stdout=encoder_log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    encoder_log.close()
    return recorder_proc, ffmpeg_proc, hls / "live.m3u8"


def playlist_ready(path: Path) -> bool:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    return text.count("#EXTINF") >= 2 and ".ts" in text


def playlist_fresh(path: Path, seconds: float = 8) -> bool:
    try:
        return time.time() - path.stat().st_mtime <= seconds
    except OSError:
        return False


def wait_playlist(path: Path, stop: threading.Event, recorder=None, ffmpeg_proc=None) -> bool:
    deadline = time.time() + 16
    while time.time() < deadline:
        if stop.is_set():
            return False
        if recorder is not None and recorder.poll() is not None:
            raise RuntimeError("The encoder stopped. See encoder.log.")
        if ffmpeg_proc is not None and ffmpeg_proc.poll() is not None:
            raise RuntimeError("The encoder stopped. See encoder.log.")
        if playlist_ready(path):
            return True
        time.sleep(0.2)
    return False


def stop_encoder(recorder: subprocess.Popen | None, ffmpeg: subprocess.Popen | None) -> None:
    if recorder is not None and recorder.poll() is None:
        kill_pid(recorder.pid)
    if ffmpeg is not None and ffmpeg.poll() is None:
        kill_pid(ffmpeg.pid)
    fifo = RUNTIME / "cast.ts"
    if fifo.exists() or fifo.is_symlink():
        try:
            fifo.unlink()
        except OSError:
            pass


def run_session(device_id: str) -> None:
    state = {
        "state": "starting",
        "id": device_id,
        "name": "",
        "detail": "Looking for the receiver.",
        "pid": os.getpid(),
    }
    write_state(state)
    session: CastSession | None = None
    recorder = None
    ffmpeg_proc = None
    server_pid = 0
    owns_server = False
    stop = threading.Event()

    def request_stop(_signum=None, _frame=None) -> None:
        stop.set()
        current = session
        if current is not None:
            try:
                current.stop_app()
            except Exception:
                pass
            current.close()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    try:
        device = find_receiver(device_id)
        if stop.is_set():
            return
        if not device.get("canMirror"):
            raise RuntimeError(device.get("note") or "This receiver cannot show the desktop.")
        model = str(device.get("model") or "")
        state["name"] = device.get("name") or device_id
        state["detail"] = f"Starting the picture for {state['name']}."
        write_state(state)
        if origin_port() is None:
            server_pid = start_server()
            owns_server = True
            state["serverPid"] = server_pid
            state["ownsServer"] = True
            write_state(state)
        if stop.is_set():
            return
        port = origin_port()
        if port is None:
            raise RuntimeError("The stream server is not listening.")
        output = ""
        deadline = time.time() + 8
        while time.time() < deadline and not output:
            if stop.is_set():
                return
            output = capture_output()
            if output:
                break
            time.sleep(0.2)
        width, height = cast_size(model, output)
        token = publish_hls_token()
        recorder, ffmpeg_proc, playlist = start_encoder(output, width, height)
        state["recorderPid"] = recorder.pid
        state["ffmpegPid"] = ffmpeg_proc.pid
        state["detail"] = "Encoding the screen."
        write_state(state)
        if not wait_playlist(playlist, stop, recorder, ffmpeg_proc):
            if stop.is_set():
                return
            raise RuntimeError("The Cast stream did not produce a playlist.")
        url = f"http://{lan_ip()}:{port}/hls/{token}/live.m3u8"
        state["url"] = url
        state["detail"] = f"Connecting to {state['name']}."
        write_state(state)
        session = CastSession(str(device["address"]), int(device.get("port") or 8009))
        session.connect()
        session.get_status()
        session.launch_default_receiver()
        media = session.load(url)
        player = ""
        for item in media.get("status") or []:
            player = str(item.get("playerState") or "")
            if player:
                break
        state["state"] = "live"
        state["detail"] = f"Mirroring to {state['name']}."
        state["player"] = player
        write_state(state)
        log(f"live {state['name']} {url} {player}")
        stall_since = time.time()
        while not stop.wait(0.5):
            if recorder.poll() is not None or ffmpeg_proc.poll() is not None:
                raise RuntimeError("The encoder stopped while mirroring.")
            if session.error:
                raise RuntimeError(session.error)
            failure = session.playback_failure()
            if failure:
                raise RuntimeError(failure)
            if playlist_fresh(playlist):
                stall_since = time.time()
            elif time.time() - stall_since > 12:
                raise RuntimeError("The picture stopped updating.")
            current_output = capture_output()
            if not current_output or current_output == output:
                continue
            log(f"output {output} -> {current_output}")
            stop_encoder(recorder, ffmpeg_proc)
            output = current_output
            width, height = cast_size(model, output)
            recorder, ffmpeg_proc, playlist = start_encoder(output, width, height)
            state["recorderPid"] = recorder.pid
            state["ffmpegPid"] = ffmpeg_proc.pid
            write_state(state)
            if not wait_playlist(playlist, stop, recorder, ffmpeg_proc):
                if stop.is_set():
                    return
                raise RuntimeError("The Cast stream did not produce a playlist.")
            session.load(url)
            stall_since = time.time()
    except Exception as exc:
        detail = str(exc)
        if session is not None and session.events:
            detail = detail + " " + session.events[-1][:180]
            for event in session.events:
                log("cast " + event)
        log(f"failed {detail}")
        state["state"] = "failed"
        state["detail"] = str(exc)
        write_state(state)
    finally:
        if session is not None:
            try:
                session.stop_app()
            finally:
                session.close()
        stop_encoder(recorder, ffmpeg_proc)
        clear_hls_token()
        if owns_server and server_pid:
            kill_pid(server_pid)
        if state.get("state") != "failed":
            state["state"] = "stopped"
            state["detail"] = "Stopped."
            write_state(state)


def detach_and_run(device_id: str) -> int:
    existing = read_state()
    if existing.get("state") in ("starting", "live") and existing.get("pid"):
        cmd_stop(quiet=True)
    pid = os.fork()
    if pid == 0:
        os.setsid()
        LOG.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        sys.stdout.flush()
        sys.stderr.flush()
        devnull = os.open(os.devnull, os.O_RDWR)
        log_fd = os.open(str(LOG), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        os.dup2(devnull, 0)
        os.dup2(log_fd, 1)
        os.dup2(log_fd, 2)
        try:
            run_session(device_id)
        except Exception as exc:
            log(f"session crashed {exc}")
            write_state({"state": "failed", "id": device_id, "name": "", "detail": str(exc)})
        os._exit(0)
    write_state(
        {
            "state": "starting",
            "id": device_id,
            "name": "",
            "detail": "Starting.",
            "pid": pid,
        }
    )
    print("Starting.")
    return 0


def cmd_stop(quiet: bool = False) -> int:
    current = read_state()
    pid = current.get("pid")
    if pid:
        kill_pid(pid)
    for key in ("recorderPid", "ffmpegPid"):
        kill_pid(current.get(key))
    if current.get("ownsServer"):
        kill_pid(current.get("serverPid"))
    fifo = RUNTIME / "cast.ts"
    if fifo.exists() or fifo.is_symlink():
        try:
            fifo.unlink()
        except OSError:
            pass
    clear_hls_token()
    write_state({"state": "stopped", "id": "", "name": "", "detail": "Stopped."})
    if not quiet:
        print("Stopped.")
    return 0


def cmd_status() -> int:
    current = read_state()
    if current.get("state") in ("starting", "live") and not pid_alive(current.get("pid")):
        cmd_stop(quiet=True)
        current = read_state()
    public = {
        "state": current.get("state") or "stopped",
        "id": current.get("id") or "",
        "name": current.get("name") or "",
        "detail": current.get("detail") or "",
        "url": current.get("url") or "",
    }
    json.dump(public, sys.stdout)
    sys.stdout.write("\n")
    return 0


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print("usage: mirror.py <id>|stop|status", file=sys.stderr)
        return 2
    if argv[0] == "stop":
        return cmd_stop()
    if argv[0] == "status":
        return cmd_status()
    device_id = argv[1] if argv[0] == "start" and len(argv) > 1 else argv[0]
    if device_id in ("start", "--id") or not device_id:
        print("usage: mirror.py <id>|stop|status", file=sys.stderr)
        return 2
    return detach_and_run(device_id)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
