#!/usr/bin/env python3
"""Two deterministic Unix-socket CAN-FD HIL endpoints."""

import argparse
import json
import os
import pathlib
import socketserver
import threading


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        request = json.loads(self.rfile.readline())
        device = self.server.device_id
        operation = request.get("op")
        if operation == "identify":
            response = {"ok": True, "device_id": device, "capability": "canfd-loopback-v3"}
        elif operation == "health":
            response = {"ok": True, "device_id": device, "heartbeat": self.server.next_heartbeat()}
        elif operation == "flash":
            response = {"ok": True, "device_id": device, "flashed": request.get("firmware_sha256")}
        elif operation == "boot":
            response = {"ok": True, "device_id": device, "bootloader": "7.4"}
        elif operation == "canfd_loopback":
            frames = int(request.get("frames", 0))
            response = {"ok": True, "device_id": device, "frames_ok": frames, "crc_errors": 0}
        else:
            response = {"ok": False, "device_id": device, "error": "unsupported_operation"}
        self.wfile.write((json.dumps(response, sort_keys=True) + "\n").encode())


class DeviceServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

    def __init__(self, path, device_id):
        self.device_id = device_id
        self._heartbeat = 0
        self._lock = threading.Lock()
        super().__init__(path, Handler)

    def next_heartbeat(self):
        with self._lock:
            self._heartbeat += 1
            return self._heartbeat


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime-dir", required=True)
    args = parser.parse_args()
    root = pathlib.Path(args.runtime_dir)
    root.mkdir(parents=True, exist_ok=True)
    servers = []
    for suffix in ("21", "22"):
        path = root / f"device-{suffix}.sock"
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        server = DeviceServer(str(path), f"canfd-rig-{suffix}")
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    threading.Event().wait()


if __name__ == "__main__":
    main()
