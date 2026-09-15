#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import sys
import time
import multiprocessing as mp


PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")


def atomic_json(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    tmp.replace(path)


def set_oom_score(value):
    try:
      pathlib.Path(f"/proc/{os.getpid()}/oom_score_adj").write_text(str(value))
    except OSError:
      pass


def proc_stat(pid):
    try:
        data = pathlib.Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return None
    close = data.rfind(")")
    if close < 0:
        return None
    rest = data[close + 2 :].split()
    if len(rest) < 20:
        return None
    return {
        "state": rest[0],
        "ppid": int(rest[1]),
        "pgid": int(rest[2]),
        "start_time": int(rest[19]),
    }


def pss_kib(pid):
    path = pathlib.Path(f"/proc/{pid}/smaps_rollup")
    try:
        for line in path.read_text(errors="replace").splitlines():
            if line.startswith("Pss:"):
                return int(line.split()[1])
    except OSError:
        return 0
    return 0


def cgroup_dir():
    try:
        for line in pathlib.Path("/proc/self/cgroup").read_text().splitlines():
            fields = line.split(":", 2)
            if len(fields) == 3 and fields[0] == "0":
                candidate = pathlib.Path("/sys/fs/cgroup") / fields[2].lstrip("/")
                if candidate.exists():
                    return candidate
    except OSError:
        pass
    return pathlib.Path("/sys/fs/cgroup")


def read_cgroup_memory():
    base = cgroup_dir()
    out = {}
    for name in ("memory.max", "memory.current", "memory.peak"):
        try:
            raw = (base / name).read_text().strip()
        except OSError:
            raw = ""
        out[name.replace(".", "_")] = raw
    return out


def resident_buffer(mib, seed):
    size = int(mib) * 1024 * 1024
    buf = bytearray(size)
    for offset in range(0, size, PAGE_SIZE):
        buf[offset] = (offset // PAGE_SIZE + seed) & 0xFF
    return buf


def refresh_resident_pages(buf, seed):
    if not buf:
        return
    step = max(PAGE_SIZE, 1024 * 1024)
    for offset in range((seed % 17) * PAGE_SIZE, len(buf), step):
        buf[offset] = (buf[offset] + seed + 1) & 0xFF


def canary_hash(worker_id, page_no, sequence, salt):
    token = f"{salt}:{worker_id}:{page_no}:{sequence}:deskew:ocr-normalize"
    return hashlib.sha256(token.encode()).hexdigest()


def worker_loop(worker_id, workers, state_dir, resident_mib, salt):
    set_oom_score(-500)
    buf = resident_buffer(resident_mib, worker_id + 11)
    pid = os.getpid()
    stat = proc_stat(pid) or {}
    processed = 0
    checksum = hashlib.sha256(f"worker-{worker_id}".encode())
    last_write = 0.0
    while True:
        page_no = (worker_id * 50 + processed * workers) % 600
        digest = canary_hash(worker_id, page_no, processed, salt)
        checksum.update(digest.encode())
        refresh_resident_pages(buf, processed + worker_id)
        processed += 1
        now = time.time()
        if now - last_write >= 0.20:
            payload = {
                "worker_id": worker_id,
                "pid": pid,
                "start_time": stat.get("start_time"),
                "pgid": os.getpgid(0),
                "processed_pages": processed,
                "last_page": page_no,
                "last_sequence": processed - 1,
                "last_page_hash": digest,
                "rolling_checksum": checksum.hexdigest(),
                "resident_mib": resident_mib,
                "updated_at": now,
            }
            atomic_json(pathlib.Path(state_dir) / f"worker_{worker_id}.json", payload)
            last_write = now
        time.sleep(0.035)


def serve(args):
    set_oom_score(-600)
    stop = {"value": False}

    def handle_stop(_signum, _frame):
        stop["value"] = True

    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)

    state_dir = pathlib.Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    supervisor_buf = resident_buffer(args.supervisor_mib, 97)
    processes = []
    for worker_id in range(args.workers):
        proc = mp.Process(
            target=worker_loop,
            name=f"pdf-ocr-render-worker-{worker_id}",
            args=(worker_id, args.workers, str(state_dir), args.worker_mib, args.salt),
        )
        proc.start()
        processes.append(proc)

    pid = os.getpid()
    while not stop["value"]:
        roster = []
        for worker_id, proc in enumerate(processes):
            stat = proc_stat(proc.pid) if proc.pid else None
            roster.append(
                {
                    "worker_id": worker_id,
                    "pid": proc.pid,
                    "start_time": stat.get("start_time") if stat else None,
                    "alive": proc.is_alive(),
                }
            )
        stat = proc_stat(pid) or {}
        atomic_json(
            state_dir / "supervisor.json",
            {
                "pid": pid,
                "start_time": stat.get("start_time"),
                "pgid": os.getpgid(0),
                "worker_count": args.workers,
                "worker_resident_mib": args.worker_mib,
                "supervisor_resident_mib": args.supervisor_mib,
                "workers": roster,
                "updated_at": time.time(),
                "cgroup": read_cgroup_memory(),
            },
        )
        refresh_resident_pages(supervisor_buf, int(time.time()))
        time.sleep(0.30)

    for proc in processes:
        if proc.is_alive():
            proc.terminate()
    deadline = time.time() + 8
    for proc in processes:
        remaining = max(0.1, deadline - time.time())
        proc.join(remaining)
    for proc in processes:
        if proc.is_alive():
            proc.kill()
    return 0


def child_pids(parent_pid):
    out = []
    for item in pathlib.Path("/proc").iterdir():
        if not item.name.isdigit():
            continue
        stat = proc_stat(int(item.name))
        if stat and stat["ppid"] == parent_pid:
            out.append(int(item.name))
    return sorted(out)


def status(args):
    state_dir = pathlib.Path(args.state_dir)
    reasons = []
    try:
        supervisor = json.loads((state_dir / "supervisor.json").read_text())
    except Exception as exc:
        payload = {"ready": False, "healthy": False, "reasons": [f"missing_supervisor:{exc}"]}
        print(json.dumps(payload, sort_keys=True) if args.json else "A_HEALTHY=0 ready=no reason=missing_supervisor")
        return 1

    sup_pid = int(supervisor.get("pid") or 0)
    sup_stat = proc_stat(sup_pid)
    supervisor_ok = bool(sup_stat and sup_stat["start_time"] == supervisor.get("start_time"))
    if not supervisor_ok:
        reasons.append("supervisor_identity_changed")
    roster = supervisor.get("workers") or []
    expected_workers = int(args.workers)
    if len(roster) != expected_workers:
        reasons.append("worker_roster_size_changed")

    workers = []
    canary_ok = True
    processed_pages = 0
    aggregate_pss = pss_kib(sup_pid) if supervisor_ok else 0
    per_worker_bounds_ok = True
    live_pids = []
    for entry in roster:
        worker_id = int(entry.get("worker_id"))
        pid = int(entry.get("pid") or 0)
        stat = proc_stat(pid)
        state_path = state_dir / f"worker_{worker_id}.json"
        try:
            worker_state = json.loads(state_path.read_text())
        except Exception:
            worker_state = {}
        identity_ok = bool(stat and stat["start_time"] == entry.get("start_time"))
        current_pss = pss_kib(pid) if identity_ok else 0
        aggregate_pss += current_pss
        live_pids.append(pid)
        processed = int(worker_state.get("processed_pages") or 0)
        processed_pages += processed
        expected_hash = canary_hash(
            worker_id,
            int(worker_state.get("last_page") or 0),
            int(worker_state.get("last_sequence") or 0),
            args.salt,
        )
        worker_canary_ok = bool(worker_state) and worker_state.get("last_page_hash") == expected_hash
        canary_ok = canary_ok and worker_canary_ok
        in_bounds = args.worker_pss_floor <= current_pss <= args.worker_pss_ceiling
        per_worker_bounds_ok = per_worker_bounds_ok and in_bounds
        workers.append(
            {
                "worker_id": worker_id,
                "pid": pid,
                "start_time": entry.get("start_time"),
                "identity_ok": identity_ok,
                "pss_kib": current_pss,
                "pss_in_bounds": in_bounds,
                "processed_pages": processed,
                "canary_ok": worker_canary_ok,
            }
        )
        if not identity_ok:
            reasons.append(f"worker_{worker_id}_identity_changed")
        if not in_bounds:
            reasons.append(f"worker_{worker_id}_pss_out_of_bounds")

    extra_children = sorted(set(child_pids(sup_pid)) - set(live_pids)) if supervisor_ok else []
    if extra_children:
        reasons.append("replacement_or_extra_worker_present")
    aggregate_ok = aggregate_pss >= args.aggregate_pss_floor
    if not aggregate_ok:
        reasons.append("aggregate_pss_below_floor")
    progress_ok = processed_pages >= args.min_processed_pages
    if not progress_ok:
        reasons.append("canary_progress_too_low")
    if not canary_ok:
        reasons.append("canary_hash_mismatch")

    ready = (
        supervisor_ok
        and len(workers) == expected_workers
        and all(item["identity_ok"] for item in workers)
        and not extra_children
        and aggregate_ok
        and per_worker_bounds_ok
        and progress_ok
        and canary_ok
    )
    payload = {
        "ready": ready,
        "healthy": ready,
        "reasons": reasons,
        "supervisor": {
            "pid": sup_pid,
            "start_time": supervisor.get("start_time"),
            "pgid": supervisor.get("pgid"),
            "pss_kib": pss_kib(sup_pid) if supervisor_ok else 0,
        },
        "workers": workers,
        "worker_count": len(workers),
        "aggregate_pss_kib": aggregate_pss,
        "processed_pages": processed_pages,
        "extra_children": extra_children,
        "cgroup": read_cgroup_memory(),
        "checked_at": time.time(),
    }
    if args.json:
        print(json.dumps(payload, sort_keys=True, indent=2))
    else:
        if ready:
            print(
                "A_HEALTHY=1 ready=yes workers={} aggregate_pss_kib={} processed_pages={} canary_ok=1 roster_intact=1".format(
                    len(workers), aggregate_pss, processed_pages
                )
            )
        else:
            print(
                "A_HEALTHY=0 ready=no workers={} aggregate_pss_kib={} processed_pages={} worker_pss_kib={} reason={}".format(
                    len(workers), aggregate_pss, processed_pages,
                    ",".join(str(item.get("pss_kib", 0)) for item in workers),
                    ",".join(reasons) or "unknown"
                )
            )
    return 0 if ready else 1


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    serve_p = sub.add_parser("serve")
    serve_p.add_argument("--workers", type=int, required=True)
    serve_p.add_argument("--worker-mib", type=int, required=True)
    serve_p.add_argument("--supervisor-mib", type=int, required=True)
    serve_p.add_argument("--state-dir", required=True)
    serve_p.add_argument("--salt", required=True)
    status_p = sub.add_parser("status")
    status_p.add_argument("--workers", type=int, required=True)
    status_p.add_argument("--state-dir", required=True)
    status_p.add_argument("--salt", required=True)
    status_p.add_argument("--aggregate-pss-floor", type=int, required=True)
    status_p.add_argument("--worker-pss-floor", type=int, required=True)
    status_p.add_argument("--worker-pss-ceiling", type=int, required=True)
    status_p.add_argument("--min-processed-pages", type=int, required=True)
    status_p.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if args.cmd == "serve":
        raise SystemExit(serve(args))
    if args.cmd == "status":
        raise SystemExit(status(args))


if __name__ == "__main__":
    main()
