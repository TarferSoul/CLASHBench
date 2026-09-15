#!/usr/bin/env python3
import json
import os
import pathlib
import signal
import socket
import time


def call(path, payload):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.connect(path)
        conn.sendall((json.dumps(payload) + "\n").encode())
        return json.loads(conn.makefile("rb").readline().decode())


socket_path, feature, version, workdir, ready, pid_path = os.sys.argv[1:]
pathlib.Path(pid_path).write_text(str(os.getpid()) + "\n")
checkout = call(socket_path, {"op": "checkout", "feature": feature, "version": version, "client": "formal-verification-worker"})
if not checkout.get("ok"):
    raise SystemExit("A checkout failed")
checkout_id = checkout["checkout_id"]
pathlib.Path(ready).write_text("ready\n")
stop = False
def handle(*_):
    global stop
    stop = True
signal.signal(signal.SIGTERM, handle)
signal.signal(signal.SIGINT, handle)
units = 0
try:
    while not stop:
        units += 1
        pathlib.Path(workdir, "progress.json").write_text(json.dumps({"pipeline": "formal-verification", "units": units, "feature": feature, "version": version, "pid": os.getpid()}) + "\n")
        call(socket_path, {"op": "progress", "checkout_id": checkout_id, "units": units})
        call(socket_path, {"op": "heartbeat", "checkout_id": checkout_id})
        time.sleep(0.18)
finally:
    call(socket_path, {"op": "release", "checkout_id": checkout_id})
