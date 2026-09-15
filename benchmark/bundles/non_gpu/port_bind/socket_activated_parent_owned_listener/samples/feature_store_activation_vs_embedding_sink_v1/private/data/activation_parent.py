#!/usr/bin/env python3
import argparse
import os
import pathlib
import signal
import socket
import subprocess
import sys
import time


def proc_start(pid):
    text = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(text[text.rfind(")") + 2:].split()[19])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--address", required=True)
    ap.add_argument("--port", required=True, type=int)
    ap.add_argument("--runtime", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--service", required=True)
    args = ap.parse_args()
    state = pathlib.Path(args.state)
    state.mkdir(parents=True, exist_ok=True)
    runtime = pathlib.Path(args.runtime)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((args.address, args.port))
    listener.listen(64)
    listener.set_inheritable(True)
    pid = os.getpid()
    inode = os.readlink(f"/proc/{pid}/fd/{listener.fileno()}").split("[")[-1].rstrip("]")
    (state / "parent.pid").write_text(f"{pid}\n")
    (state / "listener_inode").write_text(f"{inode}\n")
    (state / "parent_start").write_text(f"{proc_start(pid)}\n")
    (state / "worker_generation").write_text("0\n")
    (state / "parent.ready").write_text("ready\n")
    (state / "pre_state.json").write_text(
        '{{"parent_pid":{},"parent_start":{},"listener_inode":"{}","worker_present":false}}\n'.format(
            pid, proc_start(pid), inode
        )
    )
    identity = f"feature-store-{os.urandom(6).hex()}"
    (state / "identity").write_text(identity + "\n")
    (state / "activity").write_text("0\n")
    worker = None
    generation = 0
    activate = False
    stopping = False

    def request_activation(_signum, _frame):
        nonlocal activate
        activate = True

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGUSR1, request_activation)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(f"feature-store activation-parent ready address={args.address} port={args.port} inode={inode}", flush=True)
    try:
        while not stopping:
            if worker is not None and worker.poll() is not None:
                worker = None
                (state / "worker.pid").unlink(missing_ok=True)
                (state / "worker_listener_inode").unlink(missing_ok=True)
            if activate and worker is None:
                activate = False
                generation += 1
                (state / "worker_generation").write_text(f"{generation}\n")
                command = [
                    sys.executable,
                    str(runtime / "feature_worker.py"),
                    "--fd", str(listener.fileno()),
                    "--port", str(args.port),
                    "--state", str(state),
                    "--service", args.service,
                ]
                worker = subprocess.Popen(command, pass_fds=(listener.fileno(),), close_fds=True)
                (state / "worker.pid").write_text(f"{worker.pid}\n")
                print(f"worker_activated pid={worker.pid} generation={generation}", flush=True)
            time.sleep(0.05)
    finally:
        if worker is not None and worker.poll() is None:
            worker.terminate()
            try:
                worker.wait(timeout=2)
            except subprocess.TimeoutExpired:
                worker.kill()
        listener.close()
        for name in ("worker.pid", "worker_listener_inode", "parent.ready", "parent.pid"):
            (state / name).unlink(missing_ok=True)
        print("feature-store activation-parent stopped", flush=True)


if __name__ == "__main__":
    main()
