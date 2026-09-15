#!/usr/bin/env python3
import argparse
import base64
import json
import os
import pathlib
import socket
import struct
import time
import urllib.parse


def ws_connect(url):
    parsed = urllib.parse.urlparse(url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 80
    path = parsed.path or "/collab"
    if parsed.query:
        path += "?" + parsed.query
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    sock = socket.create_connection((host, port), timeout=5)
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(request.encode("ascii"))
    response = sock.recv(4096)
    if b" 101 " not in response.split(b"\r\n", 1)[0]:
        raise RuntimeError(f"upgrade failed: {response[:120]!r}")
    return sock


def send_text(sock, payload):
    raw = payload.encode("utf-8")
    mask = os.urandom(4)
    header = bytearray([0x81])
    if len(raw) < 126:
        header.append(0x80 | len(raw))
    elif len(raw) < 65536:
        header.append(0x80 | 126)
        header.extend(struct.pack("!H", len(raw)))
    else:
        header.append(0x80 | 127)
        header.extend(struct.pack("!Q", len(raw)))
    header.extend(mask)
    body = bytes(byte ^ mask[idx % 4] for idx, byte in enumerate(raw))
    sock.sendall(bytes(header) + body)


def recv_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    return data


def recv_text(sock):
    first = recv_exact(sock, 2)
    opcode = first[0] & 0x0F
    length = first[1] & 0x7F
    if length == 126:
        length = struct.unpack("!H", recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", recv_exact(sock, 8))[0]
    payload = recv_exact(sock, length) if length else b""
    if opcode == 8:
        raise ConnectionError("close frame")
    return payload.decode("utf-8")


def write_status(path, payload):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend-url", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--doc-id", required=True)
    parser.add_argument("--interval", type=float, default=0.2)
    args = parser.parse_args()

    state = pathlib.Path(args.state)
    state.mkdir(parents=True, exist_ok=True)
    status_path = state / "editor-client.json"
    target = (
        args.backend_url.rstrip("/")
        + f"/collab?session={urllib.parse.quote(args.session_id)}&doc={urllib.parse.quote(args.doc_id)}"
    )
    pending = []
    seq = 0
    connected = False
    try:
        sock = ws_connect(target)
        connected = True
        while True:
            seq += 1
            op_id = f"{args.doc_id}-op-{seq:04d}"
            message = {
                "type": "edit",
                "seq": seq,
                "docId": args.doc_id,
                "operationId": op_id,
                "delta": {"retain": seq % 7, "insert": f"token-{seq:04d}"},
            }
            send_text(sock, json.dumps(message, sort_keys=True))
            ack = json.loads(recv_text(sock))
            if op_id not in pending:
                pending.append(op_id)
            write_status(
                status_path,
                {
                    "connected": True,
                    "session_id": args.session_id,
                    "doc_id": args.doc_id,
                    "sent_ops": seq,
                    "highest_acknowledged_seq": int(ack.get("seq", 0)),
                    "pending_operation_ids": pending,
                    "collab_websocket_id": ack.get("collab_websocket_id", ""),
                    "hmr_generation": ack.get("hmr_generation", 0),
                    "updated_at": time.time(),
                },
            )
            time.sleep(args.interval)
    except Exception as exc:
        write_status(
            status_path,
            {
                "connected": False,
                "session_id": args.session_id,
                "doc_id": args.doc_id,
                "sent_ops": seq,
                "pending_operation_ids": pending,
                "error": repr(exc),
                "updated_at": time.time(),
            },
        )
        return 2 if connected else 1


if __name__ == "__main__":
    raise SystemExit(main())
