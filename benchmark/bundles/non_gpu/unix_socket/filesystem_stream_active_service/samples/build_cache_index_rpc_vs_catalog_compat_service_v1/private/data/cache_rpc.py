#!/usr/bin/env python3
import argparse
import json
import os
import stat
import subprocess
import sys
import time
from pathlib import Path
import socket


def rpc_call(socket_path, payload, timeout=1.5):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(timeout)
        client.connect(socket_path)
        client.sendall(json.dumps(payload, sort_keys=True).encode("utf-8") + b"\n")
        received = b""
        while not received.endswith(b"\n"):
            chunk = client.recv(65536)
            if not chunk:
                break
            received += chunk
    if not received:
        raise RuntimeError("empty RPC response")
    return json.loads(received.decode("utf-8"))


def proc_start_time(pid):
    text = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    tail = text[text.rfind(")") + 2 :].split()
    return int(tail[19])


def proc_cmdline(pid):
    path = Path(f"/proc/{pid}/cmdline")
    if not path.exists():
        return ""
    return path.read_bytes().replace(b"\0", b" ").decode("utf-8", errors="replace").strip()


def proc_net_unix_entries(socket_path):
    entries = []
    table = Path("/proc/net/unix")
    if not table.exists():
        return entries
    for line in table.read_text(errors="replace").splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 8 and parts[-1] == socket_path:
            entries.append(
                {
                    "raw": line,
                    "flags": parts[3],
                    "type": parts[4],
                    "state": parts[5],
                    "kernel_inode": parts[6],
                    "path": parts[7],
                }
            )
    return entries


def fd_socket_matches(pid, kernel_inode):
    matches = []
    fd_dir = Path(f"/proc/{pid}/fd")
    if not fd_dir.exists():
        return matches
    target = f"socket:[{kernel_inode}]"
    for item in sorted(fd_dir.iterdir(), key=lambda p: p.name):
        try:
            link = os.readlink(item)
        except OSError:
            continue
        if link == target:
            matches.append({"fd": item.name, "target": link})
    return matches


def socket_path_stat(socket_path):
    st = os.lstat(socket_path)
    return {
        "exists": True,
        "is_socket": stat.S_ISSOCK(st.st_mode),
        "mode": oct(stat.S_IMODE(st.st_mode)),
        "dev": st.st_dev,
        "inode": st.st_ino,
        "uid": st.st_uid,
        "gid": st.st_gid,
        "mtime_ns": st.st_mtime_ns,
    }


def ss_lines(socket_path):
    try:
        proc = subprocess.run(
            ["ss", "-xlpn"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=2,
            check=False,
        )
    except Exception as exc:
        return {"available": False, "error": type(exc).__name__, "lines": []}
    lines = [line for line in proc.stdout.splitlines() if socket_path in line]
    return {"available": proc.returncode == 0, "returncode": proc.returncode, "lines": lines}


def snapshot(socket_path, pid):
    payload = {
        "socket_path": socket_path,
        "pid": pid,
        "process_exists": Path(f"/proc/{pid}").exists(),
        "captured_at": time.time(),
    }
    if payload["process_exists"]:
        try:
            payload["start_time"] = proc_start_time(pid)
            payload["pgid"] = os.getpgid(pid)
            payload["cmdline"] = proc_cmdline(pid)
        except Exception as exc:
            payload["process_error"] = type(exc).__name__
    try:
        payload["path_stat"] = socket_path_stat(socket_path)
    except FileNotFoundError:
        payload["path_stat"] = {"exists": False}
    entries = proc_net_unix_entries(socket_path)
    payload["proc_net_unix"] = entries
    payload["kernel_inode"] = entries[0]["kernel_inode"] if entries else ""
    payload["fd_matches"] = fd_socket_matches(pid, payload["kernel_inode"]) if payload["kernel_inode"] else []
    payload["ss"] = ss_lines(socket_path)
    try:
        payload["stats"] = rpc_call(socket_path, {"method": "stats"})
    except Exception as exc:
        payload["stats_error"] = type(exc).__name__
    return payload


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["health", "stats", "lookup", "reserve", "commit", "snapshot", "wait"])
    parser.add_argument("--socket", required=True)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--digest", default="")
    parser.add_argument("--builder", default="fixture-client")
    parser.add_argument("--size", type=int, default=4096)
    parser.add_argument("--timeout", type=float, default=8.0)
    args = parser.parse_args()

    if args.command == "snapshot":
        if not args.pid:
            raise SystemExit("--pid required for snapshot")
        print(json.dumps(snapshot(args.socket, args.pid), sort_keys=True, indent=2))
        return
    if args.command == "wait":
        deadline = time.monotonic() + args.timeout
        last_error = ""
        while time.monotonic() < deadline:
            try:
                response = rpc_call(args.socket, {"method": "health"}, timeout=0.5)
                if response.get("ok") is True and response.get("service") == "build-cache-index":
                    print(json.dumps(response, sort_keys=True))
                    return
            except Exception as exc:
                last_error = type(exc).__name__
            time.sleep(0.1)
        raise SystemExit(f"service not ready: {last_error}")

    payload = {"method": args.command}
    if args.digest:
        payload["digest"] = args.digest
    if args.command in {"reserve", "commit"}:
        payload["builder"] = args.builder
    if args.command == "commit":
        payload["size"] = args.size
    print(json.dumps(rpc_call(args.socket, payload), sort_keys=True, indent=2))


if __name__ == "__main__":
    main()

