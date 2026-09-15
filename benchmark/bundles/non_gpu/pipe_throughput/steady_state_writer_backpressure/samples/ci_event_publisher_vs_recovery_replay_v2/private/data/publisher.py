#!/usr/bin/python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import time


stop = False


def on_signal(_signum, _frame):
    global stop
    stop = True


def write_json(path, value):
    target = pathlib.Path(path)
    tmp = pathlib.Path(str(target) + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n")
    tmp.replace(target)


def frame(record, size):
    raw = json.dumps(record, separators=(",", ":"), sort_keys=True).encode() + b"\n"
    if len(raw) > size:
        raise ValueError("frame_payload_too_large")
    return raw + b" " * (size - len(raw))


def count_receipts(receipt_dir, prefix):
    return len(list(pathlib.Path(receipt_dir).glob(prefix + "*.json")))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fifo", required=True)
    ap.add_argument("--receipt-dir", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--progress", required=True)
    ap.add_argument("--frame-bytes", type=int, required=True)
    ap.add_argument("--startup-records", type=int, required=True)
    ap.add_argument("--rate-rps", type=float, required=True)
    ap.add_argument("--label", required=True)
    args = ap.parse_args()
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    pathlib.Path(args.state).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.progress).parent.mkdir(parents=True, exist_ok=True)
    prefix = "a-" + args.label + "-"
    fifo_stat = os.stat(args.fifo)
    state = {"pid": os.getpid(), "uid": os.getuid(), "running": True,
             "startup_complete": False, "fifo_device": fifo_stat.st_dev,
             "fifo_inode": fifo_stat.st_ino}
    progress = {"pid": os.getpid(), "uid": os.getuid(), "running": True,
                "sent": 0, "acknowledged": 0, "startup_complete": False,
                "updated_at": time.time(), "fifo_device": fifo_stat.st_dev,
                "fifo_inode": fifo_stat.st_ino}
    write_json(args.state, state)
    write_json(args.progress, progress)
    fd = os.open(args.fifo, os.O_WRONLY)
    seq = 0
    try:
        for _ in range(args.startup_records):
            record_id = prefix + "startup-%04d" % seq
            payload = "ci-publisher:%s:%s" % (args.label, record_id)
            rec = {"producer": "ci-publisher", "record_id": record_id,
                   "payload": payload, "payload_sha256": hashlib.sha256(payload.encode()).hexdigest()}
            os.write(fd, frame(rec, args.frame_bytes))
            seq += 1
            progress["sent"] = seq
            progress["acknowledged"] = count_receipts(args.receipt_dir, prefix)
            progress["updated_at"] = time.time()
            write_json(args.progress, progress)
        state["startup_complete"] = True
        progress["startup_complete"] = True
        write_json(args.state, state)
        write_json(args.progress, progress)
        next_write = time.monotonic()
        delay = 1.0 / args.rate_rps
        while not stop:
            next_write += delay
            record_id = prefix + "steady-%08d" % seq
            payload = "ci-publisher:%s:%s" % (args.label, record_id)
            rec = {"producer": "ci-publisher", "record_id": record_id,
                   "payload": payload, "payload_sha256": hashlib.sha256(payload.encode()).hexdigest()}
            os.write(fd, frame(rec, args.frame_bytes))
            seq += 1
            progress["sent"] = seq
            progress["acknowledged"] = count_receipts(args.receipt_dir, prefix)
            progress["updated_at"] = time.time()
            write_json(args.progress, progress)
            remaining = next_write - time.monotonic()
            if remaining > 0:
                time.sleep(remaining)
    finally:
        progress["running"] = False
        progress["acknowledged"] = count_receipts(args.receipt_dir, prefix)
        progress["updated_at"] = time.time()
        state["running"] = False
        write_json(args.progress, progress)
        write_json(args.state, state)
        os.close(fd)


if __name__ == "__main__":
    main()
