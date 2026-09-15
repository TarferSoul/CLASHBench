#!/usr/bin/env python3
import json
import os
import signal
import socket
import time


HOST = os.environ["A_HOST"]
PORT = int(os.environ["A_PORT"])
RUN_DIR = os.environ["A_RUN_DIR"]
PID_FILE = os.environ["A_PID_FILE"]
READY_FILE = os.environ["A_READY_FILE"]
SERVICE = os.environ["A_SERVICE_NAME"]
INSTANCE = os.environ["A_INSTANCE"]
TOKEN = os.environ["A_IDENTITY_TOKEN"]


def write_json(path, value):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(value, fh, sort_keys=True)
        fh.write("\n")


def main():
    os.makedirs(RUN_DIR, exist_ok=True)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((HOST, PORT))
    sock.settimeout(0.25)
    link = os.readlink(f"/proc/{os.getpid()}/fd/{sock.fileno()}")
    inode = link[8:-1] if link.startswith("socket:[") else ""
    write_json(PID_FILE, {"pid": os.getpid(), "uid": os.getuid()})
    write_json(READY_FILE, {"ready": True, "pid": os.getpid(), "uid": os.getuid(), "host": HOST, "port": PORT, "listener_inode": inode, "service": SERVICE, "instance": INSTANCE, "identity": TOKEN})
    count = 0
    started = time.time()

    def stop(_signum, _frame):
        sock.close()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while True:
        try:
            data, addr = sock.recvfrom(65535)
        except socket.timeout:
            continue
        if data == b"__health__":
            sock.sendto(json.dumps({"ok": True, "service": SERVICE, "instance": INSTANCE, "identity": TOKEN, "pid": os.getpid(), "uid": os.getuid(), "received": count, "started_at": started}, sort_keys=True).encode(), addr)
            continue
        try:
            text = data.decode("utf-8")
            fields = text.split("|", 3)
            if len(fields) == 4 and fields[0] == "release":
                count += 1
                with open(os.path.join(RUN_DIR, "received.count"), "w", encoding="utf-8") as fh:
                    fh.write(f"{count}\n")
                sock.sendto(f"ack={count}".encode(), addr)
            else:
                sock.sendto(b"ignored", addr)
        except Exception:
            sock.sendto(b"rejected", addr)


if __name__ == "__main__":
    main()
