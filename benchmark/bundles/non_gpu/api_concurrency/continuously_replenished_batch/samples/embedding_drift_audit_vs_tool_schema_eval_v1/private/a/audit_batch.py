#!/usr/bin/env python3
"""Bounded-worker embedding retrieval drift audit."""

import argparse
import json
import multiprocessing as mp
import os
import pathlib
import signal
import time
import urllib.error
import urllib.request


STOP = False


def start_ticks(pid):
    raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(raw[raw.rfind(")") + 2 :].split()[19])


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(f"{path}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def request_case(endpoint, model, owner, run_id, case, prompt_revision):
    payload = json.dumps(
        {
            "model": model,
            "owner": owner,
            "run_id": run_id,
            "case_id": f"{case['id']}-r{prompt_revision}",
            "text": case["text"],
        }
    ).encode()
    request = urllib.request.Request(
        endpoint,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=4) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        try:
            body = json.load(error)
        except Exception:
            body = {}
        return error.code, body
    except (OSError, urllib.error.URLError):
        return 0, {}


def worker_main(index, endpoint, model, state_root, cases_file, revisions, stop_event):
    signal.signal(signal.SIGTERM, lambda _signum, _frame: stop_event.set())
    cases = json.loads(pathlib.Path(cases_file).read_text())
    queue = [
        (revision, case)
        for revision in range(1, revisions + 1)
        for offset, case in enumerate(cases)
        if offset % 4 == index
    ]
    state_path = pathlib.Path(state_root) / f"worker-{index:02d}.json"
    output_path = pathlib.Path(state_root) / f"labels-{index:02d}.jsonl"
    completed = 0
    rejected = 0
    cursor = 0
    while cursor < len(queue) and not stop_event.is_set():
        revision, case = queue[cursor]
        status, response = request_case(
            endpoint,
            model,
            f"embedding-drift-{index:02d}",
            "embedding-drift-r5",
            case,
            revision,
        )
        if status == 200:
            record = {
                "source_case_id": case["id"],
                "prompt_revision": revision,
                "status": status,
                "label": response.get("label"),
                "expected": case["expected"],
                "correct": response.get("label") == case["expected"],
                "response_id": response.get("id"),
            }
            with output_path.open("a") as stream:
                stream.write(json.dumps(record, sort_keys=True) + "\n")
            completed += 1
            cursor += 1
        elif status == 429:
            rejected += 1
            time.sleep(0.02)
        else:
            time.sleep(0.05)
        atomic_json(
            state_path,
            {
                "worker": index,
                "pid": os.getpid(),
                "starttime_ticks": start_ticks(os.getpid()),
                "completed_requests": completed,
                "rejected_requests": rejected,
                "queued_requests": len(queue),
                "remaining_requests": len(queue) - cursor,
                "last_status": status,
                "updated_at_ns": time.time_ns(),
            },
        )
    while not stop_event.wait(0.2):
        atomic_json(
            state_path,
            {
                "worker": index,
                "pid": os.getpid(),
                "starttime_ticks": start_ticks(os.getpid()),
                "completed_requests": completed,
                "rejected_requests": rejected,
                "queued_requests": len(queue),
                "remaining_requests": 0,
                "last_status": 200,
                "updated_at_ns": time.time_ns(),
            },
        )


def signal_stop(_signum, _frame):
    global STOP
    STOP = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--workers", required=True, type=int)
    parser.add_argument("--revisions", required=True, type=int)
    parser.add_argument("--state-root", required=True)
    parser.add_argument("--cases-file", required=True)
    parser.add_argument("--pid-file", required=True)
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, signal_stop)
    signal.signal(signal.SIGINT, signal_stop)
    state_root = pathlib.Path(args.state_root)
    state_root.mkdir(parents=True, exist_ok=True)
    stop_event = mp.Event()
    workers = []
    for index in range(args.workers):
        process = mp.Process(
            target=worker_main,
            args=(
                index,
                args.endpoint,
                args.model,
                args.state_root,
                args.cases_file,
                args.revisions,
                stop_event,
            ),
            name=f"embedding-drift-worker-{index:02d}",
        )
        process.start()
        workers.append(process)
    identity = f"embedding-drift-audit-{os.getpid()}-{time.time_ns()}"
    roster = {
        "identity": identity,
        "supervisor": {"pid": os.getpid(), "starttime_ticks": start_ticks(os.getpid())},
        "workers": [
            {"worker": index, "pid": process.pid, "starttime_ticks": start_ticks(process.pid)}
            for index, process in enumerate(workers)
        ],
        "model": args.model,
        "prompt_revisions": args.revisions,
    }
    atomic_json(state_root / "roster.json", roster)
    pathlib.Path(args.pid_file).write_text(f"{os.getpid()}\n")
    try:
        while not STOP:
            reports = []
            for index in range(args.workers):
                path = state_root / f"worker-{index:02d}.json"
                try:
                    reports.append(json.loads(path.read_text()))
                except (OSError, json.JSONDecodeError):
                    pass
            completed = sum(item.get("completed_requests", 0) for item in reports)
            remaining = sum(item.get("remaining_requests", 0) for item in reports)
            output_records = 0
            for index in range(args.workers):
                output = state_root / f"labels-{index:02d}.jsonl"
                if output.exists():
                    output_records += len(output.read_text().splitlines())
            atomic_json(
                state_root / "health.json",
                {
                    "service": "embedding-drift-audit",
                    "healthy": all(process.is_alive() for process in workers)
                    and len(reports) == args.workers,
                    "identity": identity,
                    "supervisor_pid": os.getpid(),
                    "worker_pids": [process.pid for process in workers],
                    "worker_count": args.workers,
                    "completed_requests": completed,
                    "remaining_requests": remaining,
                    "output_records": output_records,
                    "model": args.model,
                    "updated_at_ns": time.time_ns(),
                },
            )
            time.sleep(0.08)
    finally:
        stop_event.set()
        for process in workers:
            process.join(timeout=3)
        for process in workers:
            if process.is_alive():
                process.terminate()
                process.join(timeout=1)
        pathlib.Path(args.pid_file).unlink(missing_ok=True)


if __name__ == "__main__":
    main()
