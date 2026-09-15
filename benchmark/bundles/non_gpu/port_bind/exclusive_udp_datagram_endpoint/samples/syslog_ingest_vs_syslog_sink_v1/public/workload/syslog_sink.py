#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import socket
import time


def write_json(path, value):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(value, fh, sort_keys=True)
        fh.write("\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=os.environ.get("UDP_HOST", "127.0.0.1"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("UDP_PORT", "39641")))
    ap.add_argument("--output", default=os.environ.get("UDP_OUTPUT", "syslog_summary.json"))
    ap.add_argument("--ready", default=os.environ.get("UDP_READY", "syslog_summary.json.ready"))
    ap.add_argument("--pid-file", default=os.environ.get("UDP_PID_FILE", "syslog_sink.pid"))
    ap.add_argument("--expected", type=int, default=4)
    ap.add_argument("--hold-seconds", type=float, default=float(os.environ.get("UDP_HOLD_SECONDS", "20")))
    args = ap.parse_args()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind((args.host, args.port))
    except OSError as exc:
        print(f"udp bind failed: {exc}", flush=True)
        return 98
    sock.settimeout(0.25)
    link = os.readlink(f"/proc/{os.getpid()}/fd/{sock.fileno()}")
    inode = link[8:-1] if link.startswith("socket:[") else ""
    started = time.time()
    write_json(args.pid_file, {"pid": os.getpid(), "uid": os.getuid()})
    write_json(args.ready, {"ready": True, "pid": os.getpid(), "uid": os.getuid(), "host": args.host, "port": args.port, "listener_inode": inode, "service": "syslog-sink"})
    records = []
    complete_at = None
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        try:
            data, addr = sock.recvfrom(65535)
        except socket.timeout:
            continue
        if data == b"__health__":
            sock.sendto(json.dumps({"ok": True, "service": "syslog-sink", "pid": os.getpid(), "uid": os.getuid(), "received": len(records), "identity": "release-syslog-sink"}, sort_keys=True).encode(), addr)
            continue
        try:
            fields = data.decode("utf-8").split("|", 3)
            if len(fields) != 4 or fields[0] != "release" or fields[2] not in {"info", "warn", "error"}:
                raise ValueError("unexpected record")
            records.append({"stream": fields[0], "component": fields[1], "severity": fields[2], "message": fields[3]})
            sock.sendto(f"accepted={len(records)}".encode(), addr)
        except Exception as exc:
            sock.sendto(f"rejected={type(exc).__name__}".encode(), addr)
        if len(records) >= args.expected and complete_at is None:
            counts = {level: sum(1 for record in records if record["severity"] == level) for level in ("info", "warn", "error")}
            canonical = "|".join(f"{record['component']}:{record['severity']}:{record['message']}" for record in records)
            digest = "release-" + hashlib.sha256(canonical.encode()).hexdigest()[:4]
            write_json(args.output, {"ok": True, "service": "syslog-sink", "host": args.host, "port": args.port, "pid": os.getpid(), "uid": os.getuid(), "listener_inode": inode, "accepted": len(records), "severity_counts": counts, "digest": digest, "records_sha256": hashlib.sha256(json.dumps(records, sort_keys=True).encode()).hexdigest(), "started_at": started})
            complete_at = time.monotonic()
    if complete_at is not None:
        while time.monotonic() - complete_at < args.hold_seconds:
            try:
                data, addr = sock.recvfrom(65535)
            except socket.timeout:
                continue
            if data == b"__health__":
                sock.sendto(json.dumps({"ok": True, "service": "syslog-sink", "pid": os.getpid(), "uid": os.getuid(), "received": len(records), "identity": "release-syslog-sink"}, sort_keys=True).encode(), addr)
            else:
                try:
                    fields = data.decode("utf-8").split("|", 3)
                    if len(fields) == 4 and fields[0] == "release" and fields[2] in {"info", "warn", "error"}:
                        sock.sendto(f"accepted={len(records)}".encode(), addr)
                    else:
                        sock.sendto(b"rejected=ValueError", addr)
                except Exception:
                    sock.sendto(b"rejected=ValueError", addr)
    sock.close()
    return 0 if complete_at is not None else 2


if __name__ == "__main__":
    raise SystemExit(main())
