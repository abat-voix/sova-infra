#!/usr/bin/env python3
"""Check the authenticated WebSocket handshake and application heartbeat."""

import base64
import hashlib
import json
import os
import secrets
import socket
import ssl
import sys
import time
from urllib.parse import urlsplit


TIMEOUT_SECONDS = 8
MAX_FRAME_SIZE = 4096


def read_exact(sock: socket.socket, count: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < count:
        chunk = sock.recv(count - len(chunks))
        if not chunk:
            raise RuntimeError("WebSocket closed before completing the response.")
        chunks.extend(chunk)
    return bytes(chunks)


def send_frame(sock: socket.socket, opcode: int, payload: bytes) -> None:
    mask = secrets.token_bytes(4)
    length = len(payload)
    if length < 126:
        header = bytes((0x80 | opcode, 0x80 | length))
    elif length < 65536:
        header = bytes((0x80 | opcode, 0x80 | 126)) + length.to_bytes(2, "big")
    else:
        raise RuntimeError("Smoke payload is unexpectedly large.")
    masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    sock.sendall(header + mask + masked)


def receive_frame(sock: socket.socket) -> tuple[int, bytes]:
    first, second = read_exact(sock, 2)
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F
    if length == 126:
        length = int.from_bytes(read_exact(sock, 2), "big")
    elif length == 127:
        length = int.from_bytes(read_exact(sock, 8), "big")
    if length > MAX_FRAME_SIZE:
        raise RuntimeError("WebSocket response exceeded the smoke frame limit.")
    mask = read_exact(sock, 4) if masked else b""
    payload = read_exact(sock, length)
    if masked:
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return opcode, payload


def smoke_check() -> None:
    raw_url = os.environ["REALTIME_SMOKE_URL"]
    cookie = os.environ["REALTIME_SMOKE_SESSION_COOKIE"]
    parsed = urlsplit(raw_url)
    if parsed.scheme not in {"ws", "wss"} or not parsed.hostname:
        raise RuntimeError("REALTIME_SMOKE_URL must be a ws:// or wss:// URL.")

    port = parsed.port or (443 if parsed.scheme == "wss" else 80)
    path = parsed.path or "/"
    if parsed.query:
        path += f"?{parsed.query}"
    origin = os.getenv("REALTIME_SMOKE_ORIGIN", "")
    if not origin:
        origin_scheme = "https" if parsed.scheme == "wss" else "http"
        origin = f"{origin_scheme}://{parsed.netloc}"
    host_header = parsed.netloc
    key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
    expected_accept = base64.b64encode(
        hashlib.sha1(f"{key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11".encode()).digest()
    ).decode("ascii")

    with socket.create_connection((parsed.hostname, port), timeout=TIMEOUT_SECONDS) as raw_sock:
        raw_sock.settimeout(TIMEOUT_SECONDS)
        if parsed.scheme == "wss":
            sock = ssl.create_default_context().wrap_socket(raw_sock, server_hostname=parsed.hostname)
        else:
            sock = raw_sock

        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host_header}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            f"Origin: {origin}\r\n"
            f"Cookie: {cookie}\r\n"
            "\r\n"
        )
        sock.sendall(request.encode("ascii"))
        response = bytearray()
        while not response.endswith(b"\r\n\r\n"):
            response.extend(read_exact(sock, 1))
            if len(response) > 16_384:
                raise RuntimeError("WebSocket handshake response is too large.")
        lines = response.decode("latin-1").split("\r\n")
        if not lines[0].startswith("HTTP/1.1 101 "):
            raise RuntimeError(f"WebSocket handshake failed: {lines[0]}.")
        headers = {
            key.strip().lower(): value.strip()
            for line in lines[1:]
            if ":" in line
            for key, value in [line.split(":", 1)]
        }
        if headers.get("sec-websocket-accept") != expected_accept:
            raise RuntimeError("WebSocket handshake returned an invalid accept key.")

        ping_id = secrets.token_hex(16)
        send_frame(sock, 0x1, json.dumps({"type": "ping", "id": ping_id}).encode("utf-8"))
        deadline = time.monotonic() + TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            opcode, payload = receive_frame(sock)
            if opcode == 0x8:
                code = int.from_bytes(payload[:2], "big") if len(payload) >= 2 else 1000
                raise RuntimeError(f"WebSocket closed during heartbeat with code {code}.")
            if opcode == 0x9:
                send_frame(sock, 0xA, payload)
                continue
            if opcode != 0x1:
                continue
            response_payload = json.loads(payload)
            if response_payload == {"type": "pong", "id": ping_id}:
                return
            raise RuntimeError("WebSocket returned an unexpected heartbeat response.")
        raise RuntimeError("WebSocket heartbeat timed out.")


if __name__ == "__main__":
    try:
        smoke_check()
    except Exception as error:
        print(f"WebSocket smoke check failed: {error}", file=sys.stderr)
        raise SystemExit(1) from None
    print("WebSocket handshake and heartbeat succeeded.")
