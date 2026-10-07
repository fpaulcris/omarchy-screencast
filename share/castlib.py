#!/usr/bin/env python3
"""Small Cast v2 client for the Default Media Receiver.

The framing is the Cast protobuf, which only uses varints and strings, so
this stays on the Python standard library.
"""

from __future__ import annotations

import json
import socket
import ssl
import struct
import threading
import time
from collections import deque

CONN = "urn:x-cast:com.google.cast.tp.connection"
HEART = "urn:x-cast:com.google.cast.tp.heartbeat"
RECV = "urn:x-cast:com.google.cast.receiver"
MEDIA = "urn:x-cast:com.google.cast.media"
DEFAULT_RECEIVER = "CC1AD845"

CONNECT = {
    "type": "CONNECT",
    "origin": {},
    "userAgent": "omarchy-screencast",
    "senderInfo": {
        "sdkType": 2,
        "version": "15.0",
        "platform": 4,
        "connectionType": 1,
    },
}


def _varint(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def _read_varint(buf: bytes, index: int) -> tuple[int, int]:
    value = 0
    shift = 0
    while index < len(buf):
        byte = buf[index]
        index += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, index
        shift += 7
        if shift > 35:
            break
    raise ValueError("truncated varint")


def encode_message(source: str, dest: str, namespace: str, payload: str) -> bytes:
    def field_str(number: int, text: str) -> bytes:
        raw = text.encode()
        return bytes([(number << 3) | 2]) + _varint(len(raw)) + raw

    def field_var(number: int, value: int) -> bytes:
        return bytes([(number << 3) | 0]) + _varint(value)

    body = b"".join(
        [
            field_var(1, 0),
            field_str(2, source),
            field_str(3, dest),
            field_str(4, namespace),
            field_var(5, 0),
            field_str(6, payload),
        ]
    )
    return struct.pack(">I", len(body)) + body


def decode_message(body: bytes) -> dict[str, str]:
    index = 0
    found: dict[str, str] = {}
    names = {2: "source", 3: "dest", 4: "namespace", 6: "payload"}
    while index < len(body):
        tag = body[index]
        index += 1
        field, wire = tag >> 3, tag & 7
        if wire == 0:
            _, index = _read_varint(body, index)
        elif wire == 2:
            length, index = _read_varint(body, index)
            chunk = body[index : index + length]
            index += length
            if field in names:
                found[names[field]] = chunk.decode("utf-8", "replace")
        else:
            break
    return found


class CastSession:
    def __init__(self, host: str, port: int = 8009) -> None:
        self.host = host
        self.port = port
        self.sock: ssl.SSLSocket | None = None
        self._out_lock = threading.Lock()
        self._out: deque[bytes] = deque()
        self._request = 0
        self._closed = threading.Event()
        self.receiver_status: dict | None = None
        self.media_messages: deque[dict] = deque()
        self.events: deque[str] = deque(maxlen=30)
        self._status_event = threading.Event()
        self._media_event = threading.Event()
        self._reader: threading.Thread | None = None
        self._heartbeat: threading.Thread | None = None
        self.session_id = ""
        self.transport_id = ""
        self.error = ""
        self._last_rx = time.monotonic()

    def connect(self) -> None:
        raw = socket.create_connection((self.host, self.port), timeout=5)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        self.sock = context.wrap_socket(raw, server_hostname=self.host)
        # Wake often enough to send heartbeats. A quiet second is not a dead peer.
        self.sock.settimeout(1)
        self._last_rx = time.monotonic()
        self._send(CONN, json.dumps(CONNECT))
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()
        self._heartbeat = threading.Thread(target=self._beat, daemon=True)
        self._heartbeat.start()

    def _next_request(self) -> int:
        self._request += 1
        return self._request

    def _send(self, namespace: str, payload: str, dest: str = "receiver-0") -> None:
        if self.sock is None:
            raise ConnectionError("Cast connection is closed")
        packet = encode_message("sender-0", dest, namespace, payload)
        with self._out_lock:
            self._out.append(packet)
        if threading.current_thread() is self._reader:
            self._flush()

    def _flush(self) -> None:
        """Only the reader thread touches the TLS socket."""
        while self.sock is not None:
            with self._out_lock:
                if not self._out:
                    return
                packet = self._out[0]
            try:
                self.sock.sendall(packet)
            except TimeoutError:
                return
            with self._out_lock:
                if self._out and self._out[0] is packet:
                    self._out.popleft()

    def _recv_frame(self, size: int) -> bytes:
        buf = b""
        while len(buf) < size:
            if self._closed.is_set() or self.sock is None:
                raise ConnectionError("Cast connection closed")
            self._flush()
            try:
                chunk = self.sock.recv(size - len(buf))
            except TimeoutError:
                if not buf and time.monotonic() - self._last_rx > 15:
                    raise ConnectionError("Cast receiver stopped answering")
                continue
            if not chunk:
                raise ConnectionError("Cast connection closed")
            buf += chunk
            self._last_rx = time.monotonic()
        return buf

    def _read_loop(self) -> None:
        try:
            while not self._closed.is_set() and self.sock is not None:
                header = self._recv_frame(4)
                size = struct.unpack(">I", header)[0]
                if size <= 0 or size > 8_000_000:
                    raise ConnectionError(f"unexpected Cast frame ({size})")
                body = self._recv_frame(size)
                message = decode_message(body)
                self._handle(message.get("namespace", ""), message.get("payload", ""))
        except Exception as exc:
            if not self._closed.is_set():
                self.error = str(exc)
                self._closed.set()
                self._status_event.set()
                self._media_event.set()

    def _handle(self, namespace: str, payload: str) -> None:
        try:
            data = json.loads(payload) if payload else {}
        except json.JSONDecodeError:
            return
        kind = data.get("type")
        if kind not in ("PONG", "PING"):
            self.events.append(payload[:500])
        if namespace == HEART and kind == "PING":
            self._send(HEART, json.dumps({"type": "PONG"}))
            return
        if kind == "RECEIVER_STATUS":
            self.receiver_status = data
            self._status_event.set()
            return
        if kind in ("MEDIA_STATUS", "LOAD_FAILED", "LOAD_CANCELLED", "INVALID_REQUEST", "ERROR"):
            self.media_messages.append(data)
            self._media_event.set()

    def _beat(self) -> None:
        while not self._closed.wait(5):
            try:
                self._send(HEART, json.dumps({"type": "PING"}))
            except Exception:
                return

    def playback_failure(self) -> str:
        """Latest receiver rejection, after dropping status the live loop has seen."""
        failure = ""
        while self.media_messages:
            message = self.media_messages.popleft()
            kind = message.get("type")
            if kind in ("LOAD_FAILED", "LOAD_CANCELLED", "INVALID_REQUEST", "ERROR"):
                failure = json.dumps(message)[:300]
                continue
            for item in message.get("status") or []:
                if item.get("playerState") == "IDLE" and item.get("idleReason") in ("ERROR", "CANCELLED"):
                    failure = json.dumps(item)[:300]
        return failure

    def _wait_status(self, predicate, timeout: float) -> dict:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.error:
                raise ConnectionError(self.error)
            current = self.receiver_status
            if current and predicate(current):
                return current
            self._status_event.wait(timeout=0.2)
            self._status_event.clear()
        raise TimeoutError("the Cast device did not answer")

    def get_status(self) -> dict:
        self._status_event.clear()
        self._send(RECV, json.dumps({"type": "GET_STATUS", "requestId": self._next_request()}))
        return self._wait_status(lambda _status: True, 5)

    def launch_default_receiver(self) -> tuple[str, str]:
        def ready(status: dict) -> bool:
            for app in (status.get("status") or {}).get("applications") or []:
                if app.get("appId") == DEFAULT_RECEIVER and app.get("transportId") and app.get("sessionId"):
                    self.session_id = str(app["sessionId"])
                    self.transport_id = str(app["transportId"])
                    return True
            return False

        current = self.receiver_status
        if not (current and ready(current)):
            self._status_event.clear()
            self._send(
                RECV,
                json.dumps(
                    {
                        "type": "LAUNCH",
                        "requestId": self._next_request(),
                        "appId": DEFAULT_RECEIVER,
                    }
                ),
            )
            self._wait_status(ready, 8)
        self._send(CONN, json.dumps({"type": "CONNECT"}), dest=self.transport_id)
        return self.session_id, self.transport_id

    def load(self, url: str, content_type: str = "application/vnd.apple.mpegurl") -> dict:
        if not self.transport_id or not self.session_id:
            raise RuntimeError("Cast receiver is not launched")
        request = self._next_request()
        self.media_messages.clear()
        self._media_event.clear()
        self._send(
            MEDIA,
            json.dumps(
                {
                    "type": "LOAD",
                    "requestId": request,
                    "sessionId": self.session_id,
                    "media": {
                        "contentId": url,
                        "streamType": "LIVE",
                        "contentType": content_type,
                    },
                    "autoplay": True,
                    "currentTime": 0,
                }
            ),
            dest=self.transport_id,
        )
        return self._wait_media(12)

    def _wait_media(self, timeout: float) -> dict:
        deadline = time.time() + timeout
        asked = False
        while time.time() < deadline:
            if self.error:
                raise ConnectionError(self.error)
            while self.media_messages:
                message = self.media_messages.popleft()
                kind = message.get("type")
                if kind in ("LOAD_FAILED", "LOAD_CANCELLED", "INVALID_REQUEST", "ERROR"):
                    raise RuntimeError(json.dumps(message)[:300])
                for item in message.get("status") or []:
                    state = item.get("playerState")
                    if state in ("PLAYING", "BUFFERING", "LOADING"):
                        return message
                    if state == "IDLE" and item.get("idleReason") == "ERROR":
                        raise RuntimeError(json.dumps(item)[:300])
            if not asked and time.time() + 8 > deadline:
                asked = True
                self._send(
                    MEDIA,
                    json.dumps({"type": "GET_STATUS", "requestId": self._next_request()}),
                    dest=self.transport_id,
                )
            self._media_event.wait(timeout=0.3)
            self._media_event.clear()
        raise TimeoutError("the Cast device did not start the picture")

    def stop_app(self) -> None:
        if self.sock is None or not self.session_id:
            return
        try:
            self._send(
                RECV,
                json.dumps(
                    {
                        "type": "STOP",
                        "requestId": self._next_request(),
                        "sessionId": self.session_id,
                    }
                ),
            )
            time.sleep(0.3)
        except Exception:
            return

    def close(self) -> None:
        self._closed.set()
        sock = self.sock
        self.sock = None
        if sock is not None:
            try:
                sock.close()
            except Exception:
                pass
