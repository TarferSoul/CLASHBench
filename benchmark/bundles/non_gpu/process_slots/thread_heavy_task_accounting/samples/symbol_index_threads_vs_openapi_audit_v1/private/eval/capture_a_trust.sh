#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
. "${CGROUP_ENV:?}"
python3 - "$A_PID_FILE" "$A_HEALTH_FILE" "$A_TRUST_FILE" "$CGROUP_DIR" "$A_WORKER_THREADS" <<'PY'
import json, os, pathlib, sys, time
pid_path, health_path, trust_path, cgroup_dir, workers = sys.argv[1:]
pid, workers = int(pathlib.Path(pid_path).read_text()), int(workers)
proc = pathlib.Path(f"/proc/{pid}")
if not proc.is_dir():
    raise SystemExit("indexer process missing")
stat = (proc / "stat").read_text()
start = int(stat[stat.rfind(")") + 2:].split()[19])
health = json.loads(pathlib.Path(health_path).read_text())
tids = sorted(int(item.name) for item in (proc / "task").iterdir())
if len(tids) < workers + 1 or health.get("workers_alive") != workers:
    raise SystemExit("thread cohort incomplete")
cgroup = pathlib.Path(cgroup_dir)
value = {"pid": pid, "start_time_ticks": start, "process_group": os.getpgid(pid), "thread_ids": tids, "thread_count": len(tids), "worker_count": workers, "indexed_files": int(health["indexed_files"]), "cgroup_pids_current": int((cgroup / "pids.current").read_text()), "cgroup_pids_max": (cgroup / "pids.max").read_text().strip(), "cgroup_process_leaders": len((cgroup / "cgroup.procs").read_text().splitlines()), "captured_at_ns": time.time_ns()}
target = pathlib.Path(trust_path)
target.parent.mkdir(parents=True, exist_ok=True)
tmp = pathlib.Path(str(target) + ".tmp")
tmp.write_text(json.dumps(value, indent=2) + "\n")
tmp.replace(target)
os.chmod(target, 0o600)
print(f"A_TRUSTED=1 pid={pid} start={start} threads={len(tids)} leaders={value['cgroup_process_leaders']} pids_current={value['cgroup_pids_current']}")
PY
