#!/usr/bin/env python3
import argparse
import hashlib
import http.client
import json
import os
import pathlib
import signal
import time


def atomic_json(path, payload):
    path = pathlib.Path(path)
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    tmp.replace(path)


def make_segment(segment_number, size):
    seed = hashlib.sha256(f"ledger-postgres-basebackup-{segment_number}".encode()).digest()
    data = bytearray()
    counter = 0
    while len(data) < size:
      block = hashlib.sha256(seed + counter.to_bytes(8, "big")).digest()
      data.extend(block)
      counter += 1
    return bytes(data[:size])


def post_segment(host, port, segment_id, payload, timeout):
    digest = hashlib.sha256(payload).hexdigest()
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.request(
            "POST",
            f"/v1/basebackup/segments/{segment_id}",
            body=payload,
            headers={
                "Content-Type": "application/octet-stream",
                "Content-Length": str(len(payload)),
                "X-Segment-Sha256": digest,
            },
        )
        response = conn.getresponse()
        body = response.read()
        if response.status != 200:
            raise RuntimeError(f"segment {segment_id} status={response.status} body={body[:200]!r}")
        return json.loads(body.decode("utf-8"))["accepted"]
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--segment-bytes", type=int, required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--stop-file", required=True)
    args = parser.parse_args()

    state_dir = pathlib.Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    status_path = state_dir / "publisher_status.json"
    log_path = state_dir / "basebackup_publisher.log"
    stop_file = pathlib.Path(args.stop_file)
    running = True

    def terminate(signum, frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, terminate)
    start = time.time()
    committed_bytes = 0
    segment_number = 0
    atomic_json(
        status_path,
        {
            "ok": True,
            "pid": os.getpid(),
            "started_at": start,
            "segment_number": segment_number,
            "committed_bytes": committed_bytes,
            "last_commit_at": None,
        },
    )

    while running and not stop_file.exists():
        segment_number += 1
        segment_id = f"basebackup-{segment_number:06d}"
        payload = make_segment(segment_number, args.segment_bytes)
        try:
            accepted = post_segment(args.host, args.port, segment_id, payload, timeout=30)
            committed_bytes += int(accepted["length"])
            status = {
                "ok": True,
                "pid": os.getpid(),
                "started_at": start,
                "segment_number": segment_number,
                "committed_bytes": committed_bytes,
                "last_segment_id": segment_id,
                "last_commit_at": time.time(),
                "last_sha256": accepted["sha256"],
            }
            atomic_json(status_path, status)
            with open(log_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(status, sort_keys=True) + "\n")
        except Exception as exc:
            status = {
                "ok": False,
                "pid": os.getpid(),
                "started_at": start,
                "segment_number": segment_number,
                "committed_bytes": committed_bytes,
                "error": str(exc),
                "updated_at": time.time(),
            }
            atomic_json(status_path, status)
            with open(log_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(status, sort_keys=True) + "\n")
            time.sleep(0.3)

    final_status = {
        "ok": True,
        "pid": os.getpid(),
        "started_at": start,
        "segment_number": segment_number,
        "committed_bytes": committed_bytes,
        "stopped_at": time.time(),
    }
    atomic_json(status_path, final_status)


if __name__ == "__main__":
    main()
