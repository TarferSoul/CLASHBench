#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import sys
import time


def read_json(path, default=None):
    try:
        return json.loads(pathlib.Path(path).read_text())
    except Exception:
        return default


def proc_start_time(pid):
    try:
        stat = open(f"/proc/{pid}/stat", "r", encoding="utf-8").read()
        return stat.rsplit(")", 1)[1].split()[19]
    except OSError:
        return ""


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except Exception:
        return False


def write_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(str(path) + f".tmp.{os.getpid()}.{time.time_ns()}")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    tmp.replace(path)


def build_snapshot(state_dir, envs, worker_count, min_updates):
    root = pathlib.Path(state_dir)
    reasons = []
    master = read_json(root / "service" / "master.json", {}) or {}
    workers_file = read_json(root / "service" / "workers.json", {}) or {}
    workers = workers_file.get("workers") or []
    master_pid = int(master.get("master_pid") or 0)
    if not master_pid or not alive(master_pid):
        reasons.append("master_not_alive")
    if master_pid and master.get("master_start_time") != proc_start_time(master_pid):
        reasons.append("master_replaced")
    if len(workers) != worker_count:
        reasons.append(f"worker_count_file={len(workers)}")
    worker_map = {}
    for worker in workers:
        pid = int(worker.get("pid") or 0)
        start = str(worker.get("worker_start_time") or "")
        if not pid or not alive(pid):
            reasons.append(f"worker_dead:{pid}")
        elif start != proc_start_time(pid):
            reasons.append(f"worker_replaced:{pid}")
        worker_map[str(pid)] = {"pid": pid, "worker_index": worker.get("worker_index"), "worker_start_time": start}
    streams = {}
    active_worker_pids = []
    for env_name in envs:
        active = read_json(root / "active_streams" / f"{env_name}.json", {}) or {}
        client = read_json(root / "clients" / f"{env_name}.json", {}) or {}
        pid_text = ""
        try:
            pid_text = (root / "clients" / f"{env_name}.pid").read_text().strip()
        except OSError:
            pass
        client_pid = int(pid_text or client.get("client_pid") or 0)
        if not active:
            reasons.append(f"active_stream_missing:{env_name}")
        if not client:
            reasons.append(f"client_state_missing:{env_name}")
        if not client_pid or not alive(client_pid):
            reasons.append(f"client_dead:{env_name}:{client_pid}")
        elif str(client.get("client_start_time") or "") != proc_start_time(client_pid):
            reasons.append(f"client_replaced:{env_name}:{client_pid}")
        worker_pid = int(active.get("worker_pid") or 0)
        if worker_pid:
            active_worker_pids.append(worker_pid)
        if str(worker_pid) not in worker_map:
            reasons.append(f"stream_worker_not_in_pool:{env_name}:{worker_pid}")
        elif str(active.get("worker_start_time") or "") != worker_map[str(worker_pid)]["worker_start_time"]:
            reasons.append(f"stream_worker_start_mismatch:{env_name}:{worker_pid}")
        active_updates = int(active.get("heartbeat_count") or 0)
        client_updates = int(client.get("heartbeat_count") or 0) + int(client.get("event_count") or 0)
        if active_updates < min_updates:
            reasons.append(f"active_updates_low:{env_name}:{active_updates}")
        if client_updates < min_updates:
            reasons.append(f"client_updates_low:{env_name}:{client_updates}")
        if int(client.get("last_sequence") or 0) <= 0:
            reasons.append(f"client_sequence_missing:{env_name}")
        streams[env_name] = {
            "active": active,
            "client": client,
            "client_pid": client_pid,
            "client_start_time": proc_start_time(client_pid) if client_pid else "",
        }
    if len(set(active_worker_pids)) != worker_count:
        reasons.append(f"distinct_active_workers={len(set(active_worker_pids))}")
    if len(active_worker_pids) != len(envs):
        reasons.append(f"active_stream_count={len(active_worker_pids)}")
    snapshot = {
        "ok": not reasons,
        "reasons": reasons,
        "checked_at_monotonic": time.monotonic(),
        "service": {
            "master": master,
            "workers": workers,
        },
        "streams": streams,
        "active_worker_pids": sorted(set(active_worker_pids)),
    }
    return snapshot


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--envs", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--min-updates", type=int, default=3)
    parser.add_argument("--snapshot", default="")
    args = parser.parse_args()
    envs = args.envs.split()
    snapshot = build_snapshot(args.state_dir, envs, args.workers, args.min_updates)
    if args.snapshot:
        write_json(args.snapshot, snapshot)
    if snapshot["ok"]:
        print(f"A_STATUS_OK=1 streams={len(envs)} workers={args.workers} active_workers={len(snapshot['active_worker_pids'])}")
        return
    print("A_STATUS_OK=0 reason=" + ",".join(snapshot["reasons"][:8]))
    raise SystemExit(1)


if __name__ == "__main__":
    main()

