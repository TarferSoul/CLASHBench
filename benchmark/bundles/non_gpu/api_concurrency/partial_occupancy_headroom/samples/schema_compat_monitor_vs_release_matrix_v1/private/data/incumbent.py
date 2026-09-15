#!/usr/bin/env python3
"""Continuously audit saved SDK fixtures with a bounded useful worker pool."""

import argparse
import json
import os
import pathlib
import signal
import threading
import time
import urllib.error
import urllib.request


STOP = threading.Event()


def atomic_json(path, value):
    target = pathlib.Path(path)
    temporary = target.with_name(f".{target.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, target)


def start_ticks():
    return int(pathlib.Path(f"/proc/{os.getpid()}/stat").read_text().split(") ", 1)[1].split()[19])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--tenant", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--cases", required=True)
    parser.add_argument("--progress", required=True)
    parser.add_argument("--results", required=True)
    args = parser.parse_args()
    cases = json.loads(pathlib.Path(args.cases).read_text())
    identity = f"sdk-schema-monitor-{os.getpid()}-{time.time_ns()}"
    ticks = start_ticks()
    lock = threading.Lock()
    state = {str(i): {"completed": 0, "rejected": 0, "last_status": 0} for i in range(args.workers)}

    def persist():
        atomic_json(args.progress, {
            "service": "sdk-structured-output-compatibility-monitor",
            "identity": identity,
            "pid": os.getpid(),
            "starttime_ticks": ticks,
            "workers": args.workers,
            "owner": args.owner,
            "completed_items": sum(v["completed"] for v in state.values()),
            "rejected_items": sum(v["rejected"] for v in state.values()),
            "worker_state": state,
            "updated_at_ns": time.time_ns(),
        })

    def worker(index):
        cursor = index
        while not STOP.is_set():
            case = cases[cursor % len(cases)]
            body = json.dumps({
                "tenant": args.tenant, "model": args.model, "owner": args.owner,
                "cohort_id": f"monitor-{index}", "case": case,
            }).encode()
            req = urllib.request.Request(args.url, data=body, method="POST", headers={"Content-Type": "application/json"})
            status, response = 0, {}
            try:
                with urllib.request.urlopen(req, timeout=8) as opened:
                    status = opened.status
                    response = json.load(opened)
            except urllib.error.HTTPError as error:
                status = error.code
            except Exception:
                status = 0
            with lock:
                state[str(index)]["last_status"] = status
                if status == 200:
                    state[str(index)]["completed"] += 1
                    cursor += 1
                    with pathlib.Path(args.results).open("a", encoding="utf-8") as stream:
                        stream.write(json.dumps({"worker": index, "case_id": case["id"], "response": response}, sort_keys=True) + "\n")
                elif status == 429:
                    state[str(index)]["rejected"] += 1
                persist()
            if status not in (200, 429):
                STOP.wait(0.05)

    signal.signal(signal.SIGTERM, lambda *_: STOP.set())
    signal.signal(signal.SIGINT, lambda *_: STOP.set())
    with lock:
        persist()
    threads = [threading.Thread(target=worker, args=(i,), name=f"compat-worker-{i}") for i in range(args.workers)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    with lock:
        persist()


if __name__ == "__main__":
    main()

