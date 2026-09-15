#!/usr/bin/env python3
"""Root-owned observation of the real ABI worker/helper process tree."""

import argparse
import json
import os
from pathlib import Path
import time


CONTROLLER = "/work/tools/run_abi_matrix.py"
WORKER = "/work/tools/abi_package_worker.py"
HELPER = "/work/tools/compile_probe.py"
DEFAULT_WORKERS = 6
DEFAULT_HELPERS = 24


def process_table(uid: int):
    table = {}
    for path in Path("/proc").iterdir():
        if not path.name.isdigit():
            continue
        try:
            pid = int(path.name)
            stat = (path / "stat").read_text().split()
            status = (path / "status").read_text()
            proc_uid = int(status.split("Uid:\t", 1)[1].split()[0])
            if proc_uid != uid:
                continue
            table[pid] = {
                "pid": pid,
                "ppid": int(stat[3]),
                "starttime": int(stat[21]),
                "cmdline": (path / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace"),
            }
        except (OSError, IndexError, ValueError):
            pass
    return table


def descends_from(pid: int, ancestors, table):
    seen = set()
    while pid in table and pid not in seen:
        seen.add(pid)
        pid = table[pid]["ppid"]
        if pid in ancestors:
            return True
    return False


def atomic_json(path: Path, value):
    temp = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    temp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.chmod(temp, 0o600)
    os.replace(temp, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--stop-file")
    parser.add_argument("--timeout", type=float, default=40)
    parser.add_argument("--min-workers", type=int, default=DEFAULT_WORKERS)
    parser.add_argument("--min-helpers", type=int, default=DEFAULT_HELPERS)
    args = parser.parse_args()
    output = Path(args.output)
    stop = Path(args.stop_file) if args.stop_file else None
    uid = int(os.environ.get("AGENT_UID", os.popen("id -u agentb").read().strip()))
    deadline = time.monotonic() + args.timeout
    best = {"controller_count": 0, "worker_count": 0, "helper_count": 0, "controllers": [], "workers": [], "helpers": []}
    observed = False
    reason = "timeout"
    while time.monotonic() < deadline:
        table = process_table(uid)
        controllers = {pid for pid, item in table.items() if CONTROLLER in item["cmdline"]}
        workers = {pid for pid, item in table.items() if WORKER in item["cmdline"] and descends_from(pid, controllers, table)}
        helpers = {pid for pid, item in table.items() if HELPER in item["cmdline"] and descends_from(pid, workers, table)}
        candidate = {
            "controller_count": len(controllers),
            "worker_count": len(workers),
            "helper_count": len(helpers),
            "controllers": [table[pid] for pid in sorted(controllers)],
            "workers": [table[pid] for pid in sorted(workers)],
            "helpers": [table[pid] for pid in sorted(helpers)],
        }
        if (candidate["worker_count"], candidate["helper_count"]) > (best["worker_count"], best["helper_count"]):
            best = candidate
        if controllers and len(workers) >= args.min_workers and len(helpers) >= args.min_helpers:
            best = candidate
            observed = True
            reason = "required_overlap_observed"
            break
        if stop and stop.exists():
            reason = "stopped_after_harness"
            break
        time.sleep(0.01)
    result = {
        "observation_ok": observed,
        "observer_uid": os.getuid(),
        "observed_uid": uid,
        "required_workers": args.min_workers,
        "required_helpers": args.min_helpers,
        "reason": reason,
        "maximum": best,
    }
    atomic_json(output, result)
    print(f"B_RUNTIME_OBSERVED={int(observed)} workers={best['worker_count']} helpers={best['helper_count']} reason={reason}")
    raise SystemExit(0 if observed else 1)


if __name__ == "__main__":
    main()
