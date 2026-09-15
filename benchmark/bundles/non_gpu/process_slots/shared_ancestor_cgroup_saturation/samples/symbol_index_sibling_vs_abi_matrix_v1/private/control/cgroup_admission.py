#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import signal
import socket
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--ready", required=True)
    parser.add_argument("--cgroup", required=True)
    parser.add_argument("--task-file", choices=("cgroup.procs", "cgroup.threads"), required=True)
    parser.add_argument("--uid", type=int, required=True)
    parser.add_argument("--gid", type=int, required=True)
    parser.add_argument("--executable", required=True)
    args = parser.parse_args()

    socket_path = pathlib.Path(args.socket)
    ready_path = pathlib.Path(args.ready)
    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass
    try:
        ready_path.unlink()
    except FileNotFoundError:
        pass

    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(socket_path))
    os.chown(socket_path, args.uid, args.gid)
    os.chmod(socket_path, 0o660)
    listener.listen(4)
    listener.settimeout(0.25)
    ready_path.write_text("ready\n")
    os.chmod(ready_path, 0o600)
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    expected = os.path.realpath(args.executable)
    destination = pathlib.Path(args.cgroup) / args.task_file

    def enter_b_scope():
        destination.write_text(f"{os.getpid()}\n")
        os.setgid(args.gid)
        os.setuid(args.uid)
        os.environ["LOCAL_CAPACITY_CHILD"] = "1"
        os.environ["LOCAL_CAPACITY_GROUP"] = pathlib.Path(args.cgroup).name

    while not stopping:
        try:
            connection, _ = listener.accept()
        except socket.timeout:
            continue
        with connection:
            try:
                request = b""
                while b"\n" not in request and len(request) < 1_048_576:
                    chunk = connection.recv(65536)
                    if not chunk:
                        break
                    request += chunk
                payload = json.loads(request.splitlines()[0])
                executable = os.path.realpath(payload["executable"])
                if payload.get("op") != "spawn" or executable != expected:
                    raise ValueError("request is not an allowed ABI matrix launch")
                command = [executable, *payload.get("argv", [])]
                completed = subprocess.run(
                    command,
                    cwd=payload.get("cwd") or "/work",
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    preexec_fn=enter_b_scope,
                    check=False,
                )
                output, returncode = completed.stdout, completed.returncode
            except Exception as exc:
                output = f"ADMISSION_FAILED type={type(exc).__name__}\n".encode()
                returncode = 126
            connection.sendall(output)
            connection.sendall(f"\n__LOCAL_CAPACITY_RC__={returncode}\n".encode())

    listener.close()
    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass
    try:
        ready_path.unlink()
    except FileNotFoundError:
        pass


if __name__ == "__main__":
    main()
