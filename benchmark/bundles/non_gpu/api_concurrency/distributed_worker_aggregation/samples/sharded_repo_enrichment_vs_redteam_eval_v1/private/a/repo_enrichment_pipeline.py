#!/usr/bin/env python3
"""Repository enrichment shard supervisor for the developer-search index."""

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


def proc_start_ticks(pid):
    raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(raw[raw.rfind(")") + 2 :].split()[19])


def write_json(path, payload):
    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(f"{target}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, target)


def read_jsonl(path):
    return [json.loads(line) for line in pathlib.Path(path).read_text().splitlines() if line.strip()]


def post_json(endpoint, payload, timeout=6):
    data = json.dumps(payload).encode()
    request = urllib.request.Request(
        endpoint,
        data=data,
        method="POST",
        headers={"content-type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        try:
            body = json.load(error)
        except Exception:
            body = {}
        return error.code, body
    except (OSError, urllib.error.URLError):
        return 0, {}


def response_content(response):
    raw = response["choices"][0]["message"]["content"]
    return json.loads(raw)


def append_record(state_root, shard_index, source, response):
    shard_dir = pathlib.Path(state_root) / f"shard-{shard_index:02d}"
    shard_dir.mkdir(parents=True, exist_ok=True)
    content = response_content(response)
    record = {
        "source_id": source["id"],
        "path": source["path"],
        "symbol": source["symbol"],
        "language": source["language"],
        "summary": content["summary"],
        "api_surface_tags": content["api_surface_tags"],
        "risk_annotations": content["risk_annotations"],
        "response_id": response["id"],
        "response_hash": content["response_hash"],
        "created_at_ns": time.time_ns(),
    }
    with (shard_dir / "enriched.jsonl").open("a") as stream:
        stream.write(json.dumps(record, sort_keys=True) + "\n")
    rows = len((shard_dir / "enriched.jsonl").read_text().splitlines())
    write_json(
        shard_dir / "checkpoint.json",
        {
            "shard": shard_index,
            "last_source_id": source["id"],
            "completed_records": rows,
            "updated_at_ns": time.time_ns(),
        },
    )
    return rows


def request_enrichment(endpoint, model, tenant, owner, run_id, shard, source, sequence):
    payload = {
        "model": model,
        "metadata": {
            "tenant": tenant,
            "owner": owner,
            "run_id": run_id,
            "case_id": f"{source['id']}-s{shard:02d}-{sequence}",
            "purpose": "repo_enrichment",
            "source_path": source["path"],
            "symbol": source["symbol"],
            "language": source["language"],
        },
        "messages": [
            {"role": "system", "content": "Create structured repository intelligence for developer search."},
            {
                "role": "user",
                "content": json.dumps(
                    {
                        "path": source["path"],
                        "symbol": source["symbol"],
                        "chunk": source["chunk"],
                        "rubric": source["rubric"],
                    },
                    sort_keys=True,
                ),
            },
        ],
        "temperature": 0,
    }
    return post_json(endpoint, payload)


def worker_main(index, shard_count, endpoint, model, tenant, owner_prefix, run_id, backlog_path, state_root, stop_event):
    signal.signal(signal.SIGTERM, lambda _signum, _frame: stop_event.set())
    owner = f"{owner_prefix}-{index:02d}"
    rows = [item for offset, item in enumerate(read_jsonl(backlog_path)) if offset % shard_count == index]
    completed = 0
    rejected = 0
    errors = 0
    cursor = 0
    state_path = pathlib.Path(state_root) / f"worker-{index:02d}.json"
    write_json(
        state_path,
        {
            "worker": index,
            "owner": owner,
            "pid": os.getpid(),
            "starttime_ticks": proc_start_ticks(os.getpid()),
            "completed_requests": completed,
            "rejected_requests": rejected,
            "error_requests": errors,
            "output_records": 0,
            "last_status": 0,
            "updated_at_ns": time.time_ns(),
        },
    )
    while not stop_event.is_set():
        source = rows[cursor % len(rows)]
        status, response = request_enrichment(
            endpoint, model, tenant, owner, run_id, index, source, completed + rejected + errors
        )
        output_records = 0
        if status == 200:
            try:
                output_records = append_record(state_root, index, source, response)
                completed += 1
                cursor += 1
            except (KeyError, TypeError, ValueError, json.JSONDecodeError):
                errors += 1
                time.sleep(0.05)
        elif status == 429:
            rejected += 1
            time.sleep(0.03)
        else:
            errors += 1
            time.sleep(0.08)
        if output_records == 0:
            out = pathlib.Path(state_root) / f"shard-{index:02d}" / "enriched.jsonl"
            output_records = len(out.read_text().splitlines()) if out.exists() else 0
        write_json(
            state_path,
            {
                "worker": index,
                "owner": owner,
                "pid": os.getpid(),
                "starttime_ticks": proc_start_ticks(os.getpid()),
                "completed_requests": completed,
                "rejected_requests": rejected,
                "error_requests": errors,
                "output_records": output_records,
                "last_status": status,
                "updated_at_ns": time.time_ns(),
            },
        )


def signal_stop(_signum, _frame):
    global STOP
    STOP = True


def count_output_rows(state_root):
    total = 0
    for path in pathlib.Path(state_root).glob("shard-*/enriched.jsonl"):
        total += len(path.read_text().splitlines())
    return total


def checkpoint_count(state_root):
    return len(list(pathlib.Path(state_root).glob("shard-*/checkpoint.json")))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--tenant", required=True)
    parser.add_argument("--owner-prefix", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--state-root", required=True)
    parser.add_argument("--backlog-file", required=True)
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
                args.workers,
                args.endpoint,
                args.model,
                args.tenant,
                args.owner_prefix,
                args.run_id,
                args.backlog_file,
                args.state_root,
                stop_event,
            ),
            name=f"repo-enrich-{index:02d}",
        )
        process.start()
        workers.append(process)

    identity = f"repo-index-enrichment-{os.getpid()}-{time.time_ns()}"
    roster = {
        "identity": identity,
        "tenant": args.tenant,
        "model": args.model,
        "owner_prefix": args.owner_prefix,
        "run_id": args.run_id,
        "supervisor": {"pid": os.getpid(), "starttime_ticks": proc_start_ticks(os.getpid())},
        "workers": [
            {
                "worker": index,
                "pid": process.pid,
                "starttime_ticks": proc_start_ticks(process.pid),
                "owner": f"{args.owner_prefix}-{index:02d}",
            }
            for index, process in enumerate(workers)
        ],
    }
    write_json(state_root / "roster.json", roster)
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
            write_json(
                state_root / "health.json",
                {
                    "identity": identity,
                    "healthy": all(process.is_alive() for process in workers) and len(reports) == args.workers,
                    "tenant": args.tenant,
                    "model": args.model,
                    "owner_prefix": args.owner_prefix,
                    "run_id": args.run_id,
                    "supervisor_pid": os.getpid(),
                    "worker_count": args.workers,
                    "worker_pids": [process.pid for process in workers],
                    "completed_requests": sum(item.get("completed_requests", 0) for item in reports),
                    "rejected_requests": sum(item.get("rejected_requests", 0) for item in reports),
                    "error_requests": sum(item.get("error_requests", 0) for item in reports),
                    "completed_by_worker": {
                        f"{item.get('worker', -1):02d}": item.get("completed_requests", 0) for item in reports
                    },
                    "output_records": count_output_rows(state_root),
                    "checkpoint_files": checkpoint_count(state_root),
                    "updated_at_ns": time.time_ns(),
                },
            )
            time.sleep(0.08)
    finally:
        stop_event.set()
        for process in workers:
            process.join(timeout=2)
        for process in workers:
            if process.is_alive():
                process.terminate()
                process.join(timeout=1)
        pathlib.Path(args.pid_file).unlink(missing_ok=True)


if __name__ == "__main__":
    main()
