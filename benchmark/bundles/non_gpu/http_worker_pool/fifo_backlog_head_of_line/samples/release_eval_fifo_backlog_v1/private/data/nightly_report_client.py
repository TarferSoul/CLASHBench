#!/usr/bin/env python3
"""Submit the finite nightly eval-card queue and remain observable."""

import argparse
import json
import os
import pathlib
import queue
import threading
import time
import urllib.request


def post_one(endpoint, payload, timeout, progress_path, progress_lock, records):
    started = time.monotonic()
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload, sort_keys=True).encode("utf-8"),
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    row = {
        "request_id": payload["request_id"],
        "report_id": payload["report_id"],
        "started_at": time.time(),
        "ok": False,
    }
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = json.loads(response.read().decode("utf-8"))
            row.update(
                ok=response.status == 200,
                http_status=response.status,
                queue_ticket=body.get("queue_ticket"),
                artifact_digest=body.get("artifact_digest"),
                response_digest=body.get("response_digest"),
                elapsed_time_seconds=time.monotonic() - started,
            )
    except Exception as exc:
        row.update(error=f"{type(exc).__name__}: {exc}", elapsed_time_seconds=time.monotonic() - started)
    with progress_lock:
        records.append(row)
        progress_path.write_text(json.dumps({"pid": os.getpid(), "records": records}, sort_keys=True, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--state-root", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--timeout", type=float, default=120.0)
    args = parser.parse_args()

    state_root = pathlib.Path(args.state_root)
    state_root.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.pid_file).write_text(f"{os.getpid()}\n")
    progress_path = state_root / "nightly_client_progress.json"
    stop_path = state_root / "nightly_client.stop"
    manifest = json.loads(pathlib.Path(args.manifest).read_text())
    pending = queue.Queue()
    for payload in manifest:
        pending.put(payload)

    records = []
    progress_lock = threading.Lock()
    progress_path.write_text(
        json.dumps(
            {
                "pid": os.getpid(),
                "started_at": time.time(),
                "manifest_count": len(manifest),
                "records": records,
            },
            sort_keys=True,
            indent=2,
        )
        + "\n"
    )

    def worker():
        while True:
            try:
                payload = pending.get_nowait()
            except queue.Empty:
                return
            try:
                post_one(args.endpoint, payload, args.timeout, progress_path, progress_lock, records)
            finally:
                pending.task_done()

    threads = []
    for _ in manifest:
        thread = threading.Thread(target=worker)
        thread.start()
        threads.append(thread)

    for thread in threads:
        thread.join()

    (state_root / "nightly_client_finished.json").write_text(
        json.dumps(
            {
                "pid": os.getpid(),
                "finished_at": time.time(),
                "submitted": len(manifest),
                "completed_ok": sum(1 for row in records if row.get("ok") is True),
            },
            sort_keys=True,
            indent=2,
        )
        + "\n"
    )

    while not stop_path.exists():
        time.sleep(0.2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

