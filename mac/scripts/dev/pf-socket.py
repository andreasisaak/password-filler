#!/usr/bin/env python3
"""Kleiner Client für den Agent-Unix-Socket (gleiches Wire-Format wie Legacy-NMH).

Usage:
    /tmp/pf-socket.py ping
    /tmp/pf-socket.py config
    /tmp/pf-socket.py refresh
    /tmp/pf-socket.py lookup some.host.com
"""
import json
import os
import socket
import struct
import sys

SOCKET_PATH = os.path.expanduser(
    "~/Library/Application Support/app.passwordfiller/daemon.sock"
)


def send(payload: dict, timeout: float = 180.0) -> dict:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(SOCKET_PATH)

    body = json.dumps(payload).encode("utf-8")
    header = struct.pack("<I", len(body))
    s.sendall(header + body)

    raw_header = _read_exact(s, 4)
    (length,) = struct.unpack("<I", raw_header)
    raw_body = _read_exact(s, length)
    s.close()
    return json.loads(raw_body.decode("utf-8"))


def _read_exact(s: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise RuntimeError(f"Socket closed after {len(buf)}/{n} bytes")
        buf += chunk
    return buf


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    action = sys.argv[1]
    req: dict = {"action": action}
    if action == "lookup":
        if len(sys.argv) < 3:
            sys.exit("lookup needs a hostname")
        req["hostname"] = sys.argv[2]

    try:
        reply = send(req)
    except FileNotFoundError:
        sys.exit(f"❌ Socket nicht da: {SOCKET_PATH}\n   (Agent läuft nicht?)")
    except ConnectionRefusedError:
        sys.exit(f"❌ Verbindung refused auf {SOCKET_PATH}")
    print(json.dumps(reply, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
