#!/usr/bin/env python3
"""Productive incumbent client with a fixed pool of deployment-pinned workers."""

import argparse
import json
import pathlib
import signal
import threading
import time
import urllib.error
import urllib.request


stop = threading.Event()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--deployment", required=True)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--mode", choices=("schema", "judge"), required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    state_path = pathlib.Path(args.state)
    output_path = pathlib.Path(args.output)
    lock = threading.Lock()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    state = {
        "pid": __import__("os").getpid(),
        "deployment": args.deployment,
        "owner": args.owner,
        "workers": args.workers,
        "completed": 0,
        "failures": 0,
        "worker_state": {},
        "started_at": time.time(),
    }

    def persist():
        temporary = pathlib.Path(str(state_path) + ".tmp")
        temporary.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
        temporary.replace(state_path)

    def worker(index):
        sequence = 0
        while not stop.is_set():
            item_id = f"{args.owner}-{index}-{sequence:06d}"
            if args.mode == "schema":
                body = {
                    "deployment": args.deployment,
                    "case_id": item_id,
                    "input": f"Create a ticket with title release check {sequence} and priority medium.",
                }
            else:
                body = {
                    "deployment": args.deployment,
                    "item_id": item_id,
                    "reference": "The deployment and rubric version are pinned for reproducibility.",
                    "candidate": "The rubric version and deployment are pinned for reproducibility.",
                }
            request = urllib.request.Request(
                args.endpoint,
                data=json.dumps(body).encode(),
                headers={"Content-Type": "application/json", "X-Client-Owner": args.owner},
            )
            with lock:
                state["worker_state"][str(index)] = {"active": True, "request_id": item_id}
                state["updated_at"] = time.time()
                persist()
            record = {"worker": index, "item_id": item_id, "started_at": time.time()}
            try:
                with opener.open(request, timeout=10) as response:
                    payload = json.loads(response.read())
                    record.update(status=response.status, response=payload, finished_at=time.time())
                    with lock:
                        if response.status == 200 and payload.get("deployment") == args.deployment:
                            state["completed"] += 1
                        else:
                            state["failures"] += 1
            except (OSError, ValueError, urllib.error.HTTPError) as exc:
                record.update(status=getattr(exc, "code", 0), error=str(exc), finished_at=time.time())
                with lock:
                    state["failures"] += 1
            with lock:
                with output_path.open("a", encoding="utf-8") as stream:
                    stream.write(json.dumps(record, sort_keys=True) + "\n")
                state["worker_state"][str(index)] = {"active": False, "request_id": None}
                state["updated_at"] = time.time()
                persist()
            sequence += 1

    state_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with lock:
        persist()
    threads = [threading.Thread(target=worker, args=(index,), daemon=True) for index in range(args.workers)]
    for thread in threads:
        thread.start()
    while not stop.wait(0.1):
        if any(not thread.is_alive() for thread in threads):
            raise SystemExit(3)
    for thread in threads:
        thread.join(timeout=12)
    with lock:
        state["stopped_at"] = time.time()
        state["updated_at"] = time.time()
        persist()


if __name__ == "__main__":
    main()
