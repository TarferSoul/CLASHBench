#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import time


def load_records(path):
    return [json.loads(line) for line in pathlib.Path(path).read_text().splitlines() if line.strip()]


def make_frame(record, run_id, size):
    record_id = "b-%s-%s" % (run_id, record.get("segment_id") or record.get("event_id"))
    payload = str(record["payload"])
    value = {"producer": "release-manifest", "record_id": record_id,
             "payload": payload,
             "payload_sha256": hashlib.sha256(payload.encode()).hexdigest()}
    raw = json.dumps(value, separators=(",", ":"), sort_keys=True).encode() + b"\n"
    if len(raw) > size:
        raise ValueError("frame_payload_too_large")
    return record_id, raw + b" " * (size - len(raw))


def receipt_path(receipts, record_id):
    safe = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in record_id)
    return pathlib.Path(receipts) / (safe + ".json")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fifo", required=True)
    ap.add_argument("--receipts", required=True)
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--frame-bytes", type=int, required=True)
    ap.add_argument("--deadline", type=float, required=True)
    ap.add_argument("--max-wait", type=float, required=True)
    ap.add_argument("--min-rate", type=float, required=True)
    ap.add_argument("--run-id", required=True)
    args = ap.parse_args()
    start = time.monotonic()
    records = load_records(args.input)
    expected = [make_frame(record, args.run_id, args.frame_bytes) for record in records]
    fifo_identity = "%s:%s" % (os.stat(args.fifo).st_dev, os.stat(args.fifo).st_ino)
    blocked = 0
    accepted = []
    error = ""
    fd = None
    try:
        open_deadline = start + args.max_wait
        while fd is None and time.monotonic() < open_deadline:
            try:
                fd = os.open(args.fifo, os.O_WRONLY | os.O_NONBLOCK)
            except OSError as exc:
                error = str(exc)
                time.sleep(0.01)
        if fd is None:
            error = error or "fifo_open_timeout"
        else:
            for record_id, payload in expected:
                offset = 0
                while offset < len(payload):
                    if time.monotonic() - start > args.max_wait:
                        error = "write_wait_timeout"
                        break
                    try:
                        wrote = os.write(fd, payload[offset:])
                        offset += wrote
                    except BlockingIOError:
                        blocked += 1
                        time.sleep(0.01)
                if error:
                    break
                accepted.append(record_id)
            if not error:
                receipt_deadline = start + args.max_wait
                while time.monotonic() < receipt_deadline:
                    done = [record_id for record_id, _ in expected if receipt_path(args.receipts, record_id).is_file()]
                    if len(done) == len(expected):
                        break
                    time.sleep(0.01)
    except Exception as exc:
        error = str(exc)
    finally:
        if fd is not None:
            os.close(fd)
    elapsed = max(time.monotonic() - start, 0.000001)
    receipts = [record_id for record_id, _ in expected if receipt_path(args.receipts, record_id).is_file()]
    rate = len(receipts) / elapsed
    ok = (not error and len(receipts) == len(expected) and elapsed <= args.deadline and rate >= args.min_rate)
    result = {
        "run_id": args.run_id, "ok": bool(ok), "record_count": len(expected),
        "accepted_count": len(accepted), "receipt_count": len(receipts),
        "receipt_ids": receipts, "elapsed_seconds": round(elapsed, 6),
        "ack_rate_rps": round(rate, 3), "blocked_write_events": blocked,
        "fifo_device_inode": fifo_identity, "deadline_seconds": args.deadline,
        "min_rate_rps": args.min_rate, "error": error,
    }
    pathlib.Path(args.output).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
