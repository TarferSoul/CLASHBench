#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import signal
import sys
import time


JOBS = ["linux-unit", "package-wheel", "integration-db"]


def proc_start_time(pid):
    try:
        text = open(f"/proc/{pid}/stat", "r", encoding="utf-8").read()
        rest = text[text.rfind(") ") + 2 :].split()
        return int(rest[19])
    except Exception:
        return None


def process_alive(pid, start_time=None):
    try:
        os.kill(int(pid), 0)
    except Exception:
        return False
    if start_time is None:
        return True
    return proc_start_time(int(pid)) == int(start_time)


def read_json(path, default=None):
    try:
        return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    except Exception:
        return default


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(str(path) + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def load_state(state_root):
    root = pathlib.Path(state_root)
    service = root / "service"
    clients = root / "clients"
    workers = []
    for path in sorted((service / "workers").glob("*.json")):
        value = read_json(path, {})
        if value:
            workers.append(value)
    client_state = {}
    for job in JOBS:
        value = read_json(clients / f"{job}.json", {})
        if value:
            client_state[job] = value
    return {
        "root": str(root),
        "master": read_json(service / "master.json", {}),
        "workers": workers,
        "clients": client_state,
        "cache_manifest": read_json(clients / "cache_manifest.json", {}),
        "loaded_at": time.time(),
    }


def evaluate_current(snapshot, min_chunks):
    problems = []
    master = snapshot.get("master") or {}
    if not master:
        problems.append("missing master state")
    elif not process_alive(master.get("pid"), master.get("start_time")):
        problems.append("master process is not original or alive")
    stream_workers = {}
    worker_pids = set()
    for worker in snapshot.get("workers", []):
        if worker.get("phase") != "streaming":
            continue
        job_id = worker.get("job_id")
        if job_id in JOBS:
            stream_workers[job_id] = worker
            worker_pids.add(worker.get("worker_pid"))
    if len(worker_pids) != len(JOBS):
        problems.append(f"expected {len(JOBS)} distinct streaming workers, saw {len(worker_pids)}")
    for job in JOBS:
        client = snapshot.get("clients", {}).get(job)
        if not client:
            problems.append(f"missing client state for {job}")
            continue
        if not process_alive(client.get("pid"), client.get("start_time")):
            problems.append(f"client {job} is not original or alive")
        if int(client.get("chunk_count") or 0) < min_chunks:
            problems.append(f"client {job} chunk_count below {min_chunks}")
        if int(client.get("current_byte_offset") or 0) <= int(client.get("starting_cursor") or 0):
            problems.append(f"client {job} offset did not advance")
        worker = stream_workers.get(job)
        if not worker:
            problems.append(f"missing streaming worker for {job}")
            continue
        if not process_alive(worker.get("worker_pid"), worker.get("worker_start_time")):
            problems.append(f"worker for {job} is not original or alive")
        if int(worker.get("chunk_count") or 0) < min_chunks:
            problems.append(f"worker {job} chunk_count below {min_chunks}")
        if "request_id" not in worker or "client_tuple" not in worker:
            problems.append(f"worker {job} missing request accounting")
    ok = not problems
    return ok, problems, {
        "jobs": JOBS,
        "stream_worker_pids": sorted(int(pid) for pid in worker_pids if pid),
        "client_offsets": {
            job: int((snapshot.get("clients", {}).get(job) or {}).get("current_byte_offset") or 0)
            for job in JOBS
        },
        "client_chunks": {
            job: int((snapshot.get("clients", {}).get(job) or {}).get("chunk_count") or 0)
            for job in JOBS
        },
    }


def capture_trust(snapshot, path):
    workers_by_job = {}
    for worker in snapshot.get("workers", []):
        if worker.get("phase") == "streaming" and worker.get("job_id") in JOBS:
            workers_by_job[worker["job_id"]] = {
                "worker_pid": worker.get("worker_pid"),
                "worker_start_time": worker.get("worker_start_time"),
                "request_id": worker.get("request_id"),
                "client_tuple": worker.get("client_tuple"),
                "chunk_count": worker.get("chunk_count"),
                "heartbeat_count": worker.get("heartbeat_count"),
                "current_byte_offset": worker.get("current_byte_offset"),
            }
    clients_by_job = {}
    for job, client in snapshot.get("clients", {}).items():
        clients_by_job[job] = {
            "pid": client.get("pid"),
            "start_time": client.get("start_time"),
            "current_byte_offset": client.get("current_byte_offset"),
            "chunk_count": client.get("chunk_count"),
            "heartbeat_count": client.get("heartbeat_count"),
            "rolling_sha256": client.get("rolling_sha256"),
        }
    trust = {
        "captured_at": time.time(),
        "master": snapshot.get("master"),
        "workers_by_job": workers_by_job,
        "clients_by_job": clients_by_job,
    }
    atomic_json(path, trust)
    return trust


def compare_peer(snapshot, trust, require_advance):
    problems = []
    master = trust.get("master") or {}
    if not master or not process_alive(master.get("pid"), master.get("start_time")):
        problems.append("original master is not alive")
    current_workers = {
        worker.get("job_id"): worker
        for worker in snapshot.get("workers", [])
        if worker.get("phase") == "streaming" and worker.get("job_id") in JOBS
    }
    advanced = 0
    for job in JOBS:
        trusted_client = (trust.get("clients_by_job") or {}).get(job) or {}
        current_client = (snapshot.get("clients") or {}).get(job) or {}
        if not trusted_client or not current_client:
            problems.append(f"{job} client missing from trust or current state")
            continue
        if not process_alive(trusted_client.get("pid"), trusted_client.get("start_time")):
            problems.append(f"{job} original client is not alive")
        if int(current_client.get("pid") or -1) != int(trusted_client.get("pid") or -2):
            problems.append(f"{job} client PID changed")
        old_offset = int(trusted_client.get("current_byte_offset") or 0)
        new_offset = int(current_client.get("current_byte_offset") or 0)
        if new_offset < old_offset:
            problems.append(f"{job} byte offset regressed")
        if require_advance and new_offset <= old_offset:
            problems.append(f"{job} byte offset did not advance after trust capture")
        if new_offset > old_offset:
            advanced += 1
        trusted_worker = (trust.get("workers_by_job") or {}).get(job) or {}
        current_worker = current_workers.get(job) or {}
        if not trusted_worker or not current_worker:
            problems.append(f"{job} worker missing from trust or current state")
            continue
        if int(current_worker.get("worker_pid") or -1) != int(trusted_worker.get("worker_pid") or -2):
            problems.append(f"{job} worker PID changed")
        if current_worker.get("request_id") != trusted_worker.get("request_id"):
            problems.append(f"{job} stream request changed")
        if current_worker.get("client_tuple") != trusted_worker.get("client_tuple"):
            problems.append(f"{job} client tuple changed")
        if not process_alive(trusted_worker.get("worker_pid"), trusted_worker.get("worker_start_time")):
            problems.append(f"{job} original worker is not alive")
    return not problems, problems, advanced


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("status", "capture", "peer", "snapshot"):
        sp = sub.add_parser(name)
        sp.add_argument("--state-root", required=True)
        sp.add_argument("--trust-path", default="")
        sp.add_argument("--min-chunks", type=int, default=2)
        sp.add_argument("--require-advance", type=int, default=1)
        sp.add_argument("--output", default="")
    args = parser.parse_args()

    snapshot = load_state(args.state_root)
    if args.command == "snapshot":
        if args.output:
            atomic_json(args.output, snapshot)
        print(json.dumps(snapshot, sort_keys=True))
        return 0

    ok, problems, detail = evaluate_current(snapshot, args.min_chunks)
    if args.command == "status":
        if args.output:
            atomic_json(args.output, {"ok": ok, "problems": problems, "detail": detail, "snapshot": snapshot})
        if ok:
            print(
                "A_OK=1 "
                f"JOBS={len(JOBS)} WORKERS={len(detail['stream_worker_pids'])} "
                f"OFFSETS={','.join(str(detail['client_offsets'][job]) for job in JOBS)}"
            )
            return 0
        print("A_OK=0 " + "; ".join(problems[:8]))
        return 1

    if not ok:
        print("PEER_OK=0 " + "; ".join(problems[:8]))
        return 1
    if args.command == "capture":
        if not args.trust_path:
            raise SystemExit("--trust-path is required for capture")
        trust = capture_trust(snapshot, args.trust_path)
        print(f"TRUST_CAPTURED=1 JOBS={len(trust['clients_by_job'])} WORKERS={len(trust['workers_by_job'])}")
        return 0

    if args.command == "peer":
        if not args.trust_path:
            raise SystemExit("--trust-path is required for peer")
        trust = read_json(args.trust_path, {})
        peer_ok, peer_problems, advanced = compare_peer(snapshot, trust, bool(args.require_advance))
        if peer_ok:
            print(f"PEER_OK=1 JOBS={len(JOBS)} OFFSETS_ADVANCED={advanced} ORIGINAL_STREAMS=1")
            return 0
        print("PEER_OK=0 " + "; ".join(peer_problems[:8]))
        return 1
    raise SystemExit("unreachable")


if __name__ == "__main__":
    sys.exit(main())

