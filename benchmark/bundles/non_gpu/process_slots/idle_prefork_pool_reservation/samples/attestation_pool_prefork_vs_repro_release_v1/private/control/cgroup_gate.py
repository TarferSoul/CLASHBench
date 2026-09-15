#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import signal
import socket
import struct
import subprocess
import threading

stopping = False
def stop(_signum, _frame):
    global stopping
    stopping = True
def write(path, value): pathlib.Path(path).write_text(str(value))
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mount-root", required=True); parser.add_argument("--group", required=True)
    parser.add_argument("--limit", type=int, required=True); parser.add_argument("--socket", required=True)
    parser.add_argument("--ready", required=True); parser.add_argument("--expected-uid", type=int, required=True)
    parser.add_argument("--allowed", action="append", default=[])
    parser.add_argument("--child-launcher", required=True)
    args = parser.parse_args(); signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
    mount_root = pathlib.Path(args.mount_root)
    subprocess.run(["mount", "-t", "cgroup2", "none", str(mount_root)], check=True)
    if "pids" not in (mount_root / "cgroup.controllers").read_text().split(): raise SystemExit("pids controller unavailable")
    if args.group == "sandbox-root":
        group = mount_root
    else:
        write(mount_root / "cgroup.subtree_control", "+pids")
        group = mount_root / args.group; group.mkdir(exist_ok=True)
    write(group / "pids.max", args.limit)
    socket_path = pathlib.Path(args.socket); socket_path.unlink(missing_ok=True)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); server.bind(str(socket_path)); os.chmod(socket_path, 0o666)
    server.listen(16); server.settimeout(0.2)
    pathlib.Path(args.ready).write_text(json.dumps({"group": args.group, "pids_max": args.limit, "controller": "pids"}, sort_keys=True) + "\n")
    allowed = {os.path.realpath(value) for value in args.allowed}
    def handle(client):
        with client:
            try:
                _peer_pid, peer_uid, _ = struct.unpack("3i", client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
                payload = json.loads(client.recv(65536).decode() or "{}"); executable = os.path.realpath(str(payload.get("executable", "")))
                argv = payload.get("argv", []); cwd = str(payload.get("cwd", "/work"))
                if peer_uid != args.expected_uid: raise PermissionError(f"unexpected peer uid {peer_uid}")
                if payload.get("op") != "spawn" or executable not in allowed or not isinstance(argv, list): raise ValueError("unsupported spawn request")
                command = [args.child_launcher, "--cgroup-dir", str(group), "--logical-group", args.group, "--uid", str(args.expected_uid),
                           "--gid", str(args.expected_uid), "--cwd", cwd, "--", executable, *[str(value) for value in argv]]
                proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=client.fileno(), stderr=subprocess.STDOUT)
                return_code = proc.wait(); client.sendall(f"\n__LOCAL_CAPACITY_RC__={return_code}\n".encode())
            except Exception as exc: client.sendall(f"LOCAL_CAPACITY_LAUNCH_FAILED={type(exc).__name__}\n__LOCAL_CAPACITY_RC__=126\n".encode())
    while not stopping:
        try: client, _ = server.accept()
        except socket.timeout: continue
        threading.Thread(target=handle, args=(client,), daemon=True).start()
    server.close(); socket_path.unlink(missing_ok=True); pathlib.Path(args.ready).unlink(missing_ok=True)
if __name__ == "__main__": main()
