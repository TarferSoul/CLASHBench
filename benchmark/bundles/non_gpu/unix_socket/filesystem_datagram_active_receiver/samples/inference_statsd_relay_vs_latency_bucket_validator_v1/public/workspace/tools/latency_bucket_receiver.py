#!/usr/bin/env python3
import argparse
import json
import math
import os
import socket
import stat
import sys
import time
from pathlib import Path


BUCKETS = [50, 100, 200, 500, 1000]


def parse_statsd(line):
    line = line.strip()
    if not line or line.startswith("#"):
        return None
    if ":" not in line or "|" not in line:
        raise ValueError(f"invalid statsd sample: {line!r}")
    name, rest = line.split(":", 1)
    value_text, kind = rest.split("|", 1)
    kind = kind.split("|", 1)[0]
    if not name.startswith("llm."):
        raise ValueError(f"unexpected metric namespace: {name}")
    return {
        "metric": name,
        "value": float(value_text),
        "kind": kind,
        "raw": line,
    }


def ensure_parent(path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)


def write_json_atomic(path, data):
    ensure_parent(path)
    tmp = Path(f"{path}.tmp.{os.getpid()}")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, sort_keys=True, indent=2)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    tmp.replace(path)


def bucket_for(value):
    for bucket in BUCKETS:
        if value <= bucket:
            return bucket
    return BUCKETS[-1]


def summarize(records, socket_path):
    counters = {}
    gauges = {}
    latencies = []
    buckets = {str(bucket): 0 for bucket in BUCKETS}
    for item in records:
        metric = item["metric"]
        value = item["value"]
        kind = item["kind"]
        if kind == "c":
            counters[metric] = counters.get(metric, 0.0) + value
        elif kind == "g":
            gauges[metric] = value
        elif kind == "ms":
            latencies.append(value)
            buckets[str(bucket_for(value))] += 1

    p95_bucket = None
    if latencies:
        ordered = sorted(latencies)
        idx = max(0, min(len(ordered) - 1, math.ceil(len(ordered) * 0.95) - 1))
        p95_bucket = bucket_for(ordered[idx])

    return {
        "socket": socket_path,
        "socket_type": "SOCK_DGRAM",
        "captured_count": len(records),
        "metric_names": sorted({item["metric"] for item in records}),
        "request_count": int(counters.get("llm.requests", 0)),
        "token_counter_total": int(counters.get("llm.tokens", 0)),
        "latest_queue_depth": int(gauges.get("llm.queue_depth", 0)) if "llm.queue_depth" in gauges else None,
        "latency_bucket_counts": buckets,
        "p95_latency_bucket_ms": p95_bucket,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--raw", required=True)
    parser.add_argument("--ready", required=True)
    parser.add_argument("--expect-count", type=int, default=12)
    parser.add_argument("--max-seconds", type=float, default=8.0)
    parser.add_argument("--idle-seconds", type=float, default=0.7)
    parser.add_argument("--hold-seconds", type=float, default=120.0)
    args = parser.parse_args()

    sock_path = args.socket
    Path(sock_path).parent.mkdir(parents=True, exist_ok=True)
    existing = Path(sock_path)
    receiver = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    bound = False
    records = []
    try:
        receiver.bind(sock_path)
        bound = True
        os.chmod(sock_path, 0o660)
        receiver.settimeout(0.2)
        write_json_atomic(args.ready, {
            "socket": sock_path,
            "socket_type": "SOCK_DGRAM",
            "pid": os.getpid(),
            "ready_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })

        ensure_parent(args.raw)
        deadline = time.monotonic() + args.max_seconds
        last_packet = None
        with open(args.raw, "w", encoding="utf-8") as raw:
            while time.monotonic() < deadline:
                if args.expect_count and len(records) >= args.expect_count:
                    break
                if last_packet is not None and time.monotonic() - last_packet > args.idle_seconds:
                    break
                try:
                    payload = receiver.recv(8192).decode("utf-8", errors="replace")
                except socket.timeout:
                    continue
                for line in payload.splitlines():
                    parsed = parse_statsd(line)
                    if parsed is None:
                        continue
                    parsed["index"] = len(records) + 1
                    parsed["received_at"] = time.time()
                    records.append(parsed)
                    raw.write(json.dumps(parsed, sort_keys=True) + "\n")
                    raw.flush()
                    os.fsync(raw.fileno())
                    last_packet = time.monotonic()

        write_json_atomic(args.out, summarize(records, sock_path))
        if len(records) < args.expect_count:
            return 1

        hold_deadline = time.monotonic() + max(0.0, args.hold_seconds)
        while time.monotonic() < hold_deadline:
            try:
                payload = receiver.recv(8192).decode("utf-8", errors="replace")
            except socket.timeout:
                continue
            for line in payload.splitlines():
                parsed = parse_statsd(line)
                if parsed is None:
                    continue
                parsed["index"] = len(records) + 1
                parsed["received_at"] = time.time()
                parsed["phase"] = "live_verification"
                records.append(parsed)
                with open(args.raw, "a", encoding="utf-8") as raw:
                    raw.write(json.dumps(parsed, sort_keys=True) + "\n")
                    raw.flush()
                    os.fsync(raw.fileno())
        return 0
    except OSError as exc:
        print(f"cannot bind or receive on {sock_path}: {exc}", file=sys.stderr)
        return 98 if getattr(exc, "errno", None) in (98, 48) else 1
    finally:
        receiver.close()
        if bound:
            try:
                if existing.exists() and stat.S_ISSOCK(existing.stat().st_mode):
                    existing.unlink()
            except OSError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
