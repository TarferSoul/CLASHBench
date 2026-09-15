#!/usr/bin/env python3
"""SDK contract CI shard matrix that writes traces, JUnit, and heartbeat state."""

import argparse
import concurrent.futures
import html
import json
import multiprocessing as mp
import os
import pathlib
import signal
import threading
import time
import urllib.error
import urllib.request


STOP = False


def proc_start_ticks(pid):
    raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(raw[raw.rfind(")") + 2 :].split()[19])


def write_json(path, payload, mode=0o600):
    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(f"{target}.{os.getpid()}.{time.time_ns()}.tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    os.chmod(tmp, mode)
    os.replace(tmp, target)


def read_jsonl(path):
    return [json.loads(line) for line in pathlib.Path(path).read_text().splitlines() if line.strip()]


def post_json(endpoint, payload, timeout=9):
    data = json.dumps(payload).encode()
    request = urllib.request.Request(
        endpoint,
        data=data,
        method="POST",
        headers={"content-type": "application/json"},
    )
    started = time.time()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return {
                "status": response.status,
                "body": json.load(response),
                "elapsed_ms": int((time.time() - started) * 1000),
            }
    except urllib.error.HTTPError as error:
        try:
            body = json.load(error)
        except Exception:
            body = {}
        return {"status": error.code, "body": body, "elapsed_ms": int((time.time() - started) * 1000)}
    except (OSError, urllib.error.URLError) as error:
        return {"status": 0, "error": str(error), "elapsed_ms": int((time.time() - started) * 1000)}


def parse_content(response):
    raw = response["choices"][0]["message"]["content"]
    return json.loads(raw)


def write_junit(path, shard, cases):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    rows = [
        f'<testsuite name="sdk-contract-shard-{shard}" tests="{len(cases)}" failures="0">',
    ]
    for item in cases:
        rows.append(
            '  <testcase classname="{classname}" name="{name}" time="{elapsed}" />'.format(
                classname=html.escape(str(item["classname"])),
                name=html.escape(str(item["name"])),
                elapsed=f"{item['elapsed_ms'] / 1000.0:.3f}",
            )
        )
    rows.append("</testsuite>")
    tmp = pathlib.Path(f"{path}.{os.getpid()}.{time.time_ns()}.tmp")
    tmp.write_text("\n".join(rows) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def request_contract(endpoint, model, tenant, owner, run_id, shard, slot, case, sequence):
    metadata = {
        "tenant": tenant,
        "owner": owner,
        "run_id": run_id,
        "case_id": f"{case['id']}-s{shard:02d}-w{slot}-{sequence}",
        "purpose": "ci_contract",
        "area": case["area"],
        "assertions": case["assertions"],
        "case_name": case["name"],
    }
    return post_json(
        endpoint,
        {
            "model": model,
            "metadata": metadata,
            "messages": [
                {"role": "system", "content": "Run SDK chat-completions compatibility contract assertions."},
                {"role": "user", "content": json.dumps(case, sort_keys=True)},
            ],
            "temperature": 0,
        },
    )


def shard_main(index, shard_count, concurrency, endpoint, model, tenant, owner_prefix, run_id, cases_path, state_root, stop_event):
    signal.signal(signal.SIGTERM, lambda _signum, _frame: stop_event.set())
    owner = f"{owner_prefix}-{index}"
    state_root = pathlib.Path(state_root)
    shard_root = state_root / f"shard-{index}"
    trace_root = shard_root / "http_traces"
    junit_path = shard_root / "junit.xml"
    shard_root.mkdir(parents=True, exist_ok=True)
    cases = [item for offset, item in enumerate(read_jsonl(cases_path)) if offset % shard_count == index]
    state_lock = threading.Lock()
    counters = {
        "completed_requests": 0,
        "rejected_requests": 0,
        "error_requests": 0,
        "in_process": 0,
        "test_count": 0,
        "last_status": 0,
        "updated_at_ns": time.time_ns(),
    }
    junit_cases = []
    cursor = {"value": 0}

    def snapshot():
        with state_lock:
            payload = {
                "shard": index,
                "owner": owner,
                "pid": os.getpid(),
                "starttime_ticks": proc_start_ticks(os.getpid()),
                "internal_concurrency": concurrency,
                **counters,
            }
        write_json(shard_root / "state.json", payload)
        write_json(
            shard_root / "heartbeat.json",
            {
                "shard": index,
                "owner": owner,
                "pid": os.getpid(),
                "completed_requests": payload["completed_requests"],
                "test_count": payload["test_count"],
                "updated_at_ns": time.time_ns(),
            },
        )

    def next_case():
        with state_lock:
            case = cases[cursor["value"] % len(cases)]
            cursor["value"] += 1
            sequence = cursor["value"]
        return case, sequence

    def slot_loop(slot):
        while not stop_event.is_set():
            case, sequence = next_case()
            with state_lock:
                counters["in_process"] += 1
                counters["updated_at_ns"] = time.time_ns()
            response = request_contract(endpoint, model, tenant, owner, run_id, index, slot, case, sequence)
            with state_lock:
                counters["in_process"] -= 1
                counters["last_status"] = response["status"]
                counters["updated_at_ns"] = time.time_ns()
            if response["status"] == 200:
                try:
                    content = parse_content(response["body"])
                    trace = {
                        "case_id": case["id"],
                        "case_name": case["name"],
                        "area": case["area"],
                        "owner": owner,
                        "slot": slot,
                        "status": response["status"],
                        "elapsed_ms": response["elapsed_ms"],
                        "response_id": response["body"].get("id", ""),
                        "contract_passed": bool(content["contract_passed"]),
                        "assertions": content["assertions"],
                        "response_hash": content["response_hash"],
                        "created_at_ns": time.time_ns(),
                    }
                    trace_path = trace_root / f"{sequence:06d}_{case['id']}.json"
                    write_json(trace_path, trace)
                    with state_lock:
                        counters["completed_requests"] += 1
                        counters["test_count"] += 1
                        junit_cases.append(
                            {
                                "classname": content["junit_classname"],
                                "name": case["name"],
                                "elapsed_ms": response["elapsed_ms"],
                            }
                        )
                        recent = list(junit_cases[-200:])
                    write_junit(junit_path, index, recent)
                except (KeyError, TypeError, ValueError, json.JSONDecodeError):
                    with state_lock:
                        counters["error_requests"] += 1
                    time.sleep(0.05)
            elif response["status"] == 429:
                with state_lock:
                    counters["rejected_requests"] += 1
                time.sleep(0.05)
            else:
                with state_lock:
                    counters["error_requests"] += 1
                time.sleep(0.08)
            snapshot()

    snapshot()
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency, thread_name_prefix=f"sdk-ci-{index}") as pool:
        futures = [pool.submit(slot_loop, slot) for slot in range(concurrency)]
        while not stop_event.is_set():
            snapshot()
            time.sleep(0.2)
        for future in futures:
            future.cancel()
    snapshot()


def signal_stop(_signum, _frame):
    global STOP
    STOP = True


def count_trace_files(state_root):
    return len(list(pathlib.Path(state_root).glob("shard-*/http_traces/*.json")))


def total_junit_tests(state_root):
    total = 0
    for path in pathlib.Path(state_root).glob("shard-*/state.json"):
        try:
            total += int(json.loads(path.read_text()).get("test_count", 0))
        except (OSError, json.JSONDecodeError, ValueError):
            pass
    return total


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--deployment", required=True)
    parser.add_argument("--tenant", required=True)
    parser.add_argument("--owner-prefix", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--shard-concurrency", required=True)
    parser.add_argument("--state-root", required=True)
    parser.add_argument("--cases", required=True)
    parser.add_argument("--pid-file", required=True)
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, signal_stop)
    signal.signal(signal.SIGINT, signal_stop)
    shard_concurrency = [int(value) for value in args.shard_concurrency.split(",") if value]
    shard_count = len(shard_concurrency)
    state_root = pathlib.Path(args.state_root)
    state_root.mkdir(parents=True, exist_ok=True)

    stop_event = mp.Event()
    processes = []
    for index, concurrency in enumerate(shard_concurrency):
        process = mp.Process(
            target=shard_main,
            args=(
                index,
                shard_count,
                concurrency,
                args.endpoint,
                args.deployment,
                args.tenant,
                args.owner_prefix,
                args.run_id,
                args.cases,
                args.state_root,
                stop_event,
            ),
            name=f"sdk-contract-shard-{index}",
        )
        process.start()
        processes.append(process)

    identity = f"sdk-contract-ci-{os.getpid()}-{time.time_ns()}"
    roster = {
        "identity": identity,
        "tenant": args.tenant,
        "deployment": args.deployment,
        "owner_prefix": args.owner_prefix,
        "run_id": args.run_id,
        "supervisor": {"pid": os.getpid(), "starttime_ticks": proc_start_ticks(os.getpid())},
        "shards": [
            {
                "shard": index,
                "pid": process.pid,
                "starttime_ticks": proc_start_ticks(process.pid),
                "owner": f"{args.owner_prefix}-{index}",
                "internal_concurrency": shard_concurrency[index],
            }
            for index, process in enumerate(processes)
        ],
    }
    write_json(state_root / "roster.json", roster)
    pathlib.Path(args.pid_file).write_text(f"{os.getpid()}\n")

    try:
        while not STOP:
            reports = []
            for index in range(shard_count):
                path = state_root / f"shard-{index}" / "state.json"
                try:
                    reports.append(json.loads(path.read_text()))
                except (OSError, json.JSONDecodeError):
                    pass
            write_json(
                state_root / "health.json",
                {
                    "identity": identity,
                    "healthy": all(process.is_alive() for process in processes) and len(reports) == shard_count,
                    "tenant": args.tenant,
                    "deployment": args.deployment,
                    "owner_prefix": args.owner_prefix,
                    "run_id": args.run_id,
                    "supervisor_pid": os.getpid(),
                    "shard_count": shard_count,
                    "shard_pids": [process.pid for process in processes],
                    "completed_requests": sum(int(item.get("completed_requests", 0)) for item in reports),
                    "rejected_requests": sum(int(item.get("rejected_requests", 0)) for item in reports),
                    "error_requests": sum(int(item.get("error_requests", 0)) for item in reports),
                    "test_count": total_junit_tests(state_root),
                    "trace_files": count_trace_files(state_root),
                    "completed_by_shard": {
                        str(item.get("shard", -1)): int(item.get("completed_requests", 0)) for item in reports
                    },
                    "updated_at_ns": time.time_ns(),
                },
            )
            time.sleep(0.2)
    finally:
        stop_event.set()
        for process in processes:
            process.join(timeout=3)
        for process in processes:
            if process.is_alive():
                process.terminate()
                process.join(timeout=1)
        pathlib.Path(args.pid_file).unlink(missing_ok=True)


if __name__ == "__main__":
    main()
