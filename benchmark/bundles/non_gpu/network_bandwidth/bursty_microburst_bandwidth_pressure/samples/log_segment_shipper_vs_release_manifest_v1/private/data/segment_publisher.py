#!/usr/bin/env python3
"""Publish verified engineering data shards at explicit phase boundaries."""
import argparse
import concurrent.futures
import hashlib
import json
import os
import socket
import time
from pathlib import Path


def atomic_json(path: Path, value):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n")
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def payload(context: str, cycle: int, rendition: int, size: int) -> bytes:
    seed = hashlib.sha256(f"{context}-segment:{cycle}:{rendition}".encode()).digest()
    return (seed * ((size // len(seed)) + 1))[:size]


def send_one(context, host, port, cycle, rendition, data, timeout):
    digest = hashlib.sha256(data).hexdigest()
    header = {"kind": f"{context}-shard", "name": f"{context}-{cycle:03d}-part{rendition}", "size": len(data), "sha256": digest, "revision": f"{context}-cycle-{cycle:03d}"}
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall((json.dumps(header) + "\n").encode() + data)
        response = b""
        while not response.endswith(b"\n"):
            part = sock.recv(4096)
            if not part:
                raise ConnectionError("receiver closed before commit")
            response += part
        result = json.loads(response.decode())
        if result.get("committed") is not True or result.get("sha256") != digest:
            raise RuntimeError("receiver did not commit rendition")
    return {"cycle": cycle, "rendition": rendition, "size": len(data), "sha256": digest}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--cycles", type=int, required=True)
    ap.add_argument("--renditions", type=int, required=True)
    ap.add_argument("--segment-bytes", type=int, required=True)
    ap.add_argument("--phase-lead-ms", type=int, default=80)
    ap.add_argument("--quiet-ms", type=int, default=350)
    ap.add_argument("--context", default=os.environ.get("A_CONTEXT", "workload"))
    ap.add_argument("--pid-file")
    args = ap.parse_args()
    if args.pid_file:
        Path(args.pid_file).write_text(str(os.getpid()) + "\n")
        os.chmod(args.pid_file, 0o600)
    root = Path(args.state)
    root.mkdir(parents=True, exist_ok=True)
    phase = root / "phase.json"
    progress = root / "progress.json"
    events = root / "events.jsonl"
    atomic_json(progress, {"cycle": 0, "completed": 0, "bytes": 0, "errors": 0, "updated_at": time.time()})
    for cycle in range(1, args.cycles + 1):
        atomic_json(phase, {"cycle": cycle, "phase": "dispatching", "updated_at": time.time()})
        time.sleep(args.phase_lead_ms / 1000.0)
        atomic_json(phase, {"cycle": cycle, "phase": "burst", "updated_at": time.time()})
        begun = time.time()
        results = []
        errors = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.renditions) as pool:
            futures = [pool.submit(send_one, args.context, args.host, args.port, cycle, rendition, payload(args.context, cycle, rendition, args.segment_bytes), 12.0) for rendition in range(args.renditions)]
            for future in futures:
                try:
                    results.append(future.result())
                except Exception as exc:
                    errors.append(type(exc).__name__)
        previous = json.loads(progress.read_text())
        previous.update({"cycle": cycle, "completed": previous.get("completed", 0) + len(results), "bytes": previous.get("bytes", 0) + sum(x["size"] for x in results), "errors": previous.get("errors", 0) + len(errors), "updated_at": time.time(), "last_elapsed_ms": round((time.time() - begun) * 1000, 2)})
        atomic_json(progress, previous)
        with events.open("a") as handle:
            handle.write(json.dumps({"event": "segment", "cycle": cycle, "committed": len(results), "errors": errors, "at": time.time()}) + "\n")
        atomic_json(phase, {"cycle": cycle, "phase": "quiet", "updated_at": time.time()})
        time.sleep(args.quiet_ms / 1000.0)
    atomic_json(phase, {"cycle": args.cycles, "phase": "complete", "updated_at": time.time()})


if __name__ == "__main__":
    main()
