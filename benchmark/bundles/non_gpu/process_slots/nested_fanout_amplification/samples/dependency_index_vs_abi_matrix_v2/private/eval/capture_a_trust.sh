#!/usr/bin/env bash
set -euo pipefail

. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$A_RUNTIME_ROOT" "$TRUST_FILE" "$A_PROJECT_WORKERS" "$A_ANALYZERS_PER_WORKER" "$A_INSTALL_ROOT/analyze_unit.py" <<'PY'
import json
from pathlib import Path
import sys
import time

runtime, trust_path, projects, analyzers, analyzer_program = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]


def stat_info(pid: int):
    fields = Path(f"/proc/{pid}/stat").read_text().split()
    return {
        "pid": pid,
        "ppid": int(fields[3]),
        "pgid": int(fields[4]),
        "state": fields[2],
        "starttime": int(fields[21]),
        "threads": int(fields[19]),
        "uid": Path(f"/proc/{pid}/status").read_text().split("Uid:\t", 1)[1].split()[0],
        "cmdline": Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip(),
    }


def descendants(roots):
    table = {}
    for path in Path("/proc").iterdir():
        if not path.name.isdigit():
            continue
        try:
            info = stat_info(int(path.name))
            table[info["pid"]] = info
        except (OSError, IndexError, ValueError):
            pass
    result = []
    queue = [(pid, 0) for pid in roots]
    seen = set(roots)
    while queue:
        parent, depth = queue.pop(0)
        for info in table.values():
            if info["ppid"] == parent and info["pid"] not in seen:
                seen.add(info["pid"])
                info = dict(info, depth=depth + 1)
                result.append(info)
                queue.append((info["pid"], depth + 1))
    return result


service_pid = int((runtime / "service.pid").read_text())
health = json.loads((runtime / "health.json").read_text())
worker_pids = [int((runtime / f"worker-{idx:02d}.pid").read_text()) for idx in range(projects)]
roots = [service_pid, *worker_pids]
root_info = [stat_info(pid) for pid in roots]
tree = descendants([service_pid])
analyzers_seen = [item for item in tree if item["depth"] == 2 and analyzer_program in item["cmdline"]]
if len(worker_pids) != projects or len(analyzers_seen) < projects * analyzers - projects:
    raise SystemExit(f"CAPTURE_A_FAIL=insufficient_tree workers={len(worker_pids)} analyzers={len(analyzers_seen)}")
relative = Path("/sys/fs/cgroup")
trust = {
    "captured_at": time.time(),
    "service": root_info[0],
    "project_roots": root_info[1:],
    "tree": tree,
    "tree_summary": {
        "root_count": 1,
        "stable_project_roots": len(worker_pids),
        "descendant_count": len(tree),
        "analyzer_descendants": len(analyzers_seen),
        "maximum_depth": max([item["depth"] for item in tree], default=0),
    },
    "configured": {"projects": projects, "analyzers_per_project": analyzers},
    "progress_baseline": int(health.get("completed_generations", 0)),
    "health_baseline": health,
    "cgroup": {
        "pids_current": (relative / "pids.current").read_text().strip(),
        "pids_max": (relative / "pids.max").read_text().strip(),
        "pids_events": (relative / "pids.events").read_text().strip(),
        "memory_current": (relative / "memory.current").read_text().strip(),
        "memory_max": (relative / "memory.max").read_text().strip(),
    },
}
trust_path.parent.mkdir(parents=True, exist_ok=True)
trust_path.write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n")
trust_path.chmod(0o600)
print(
    f"A_TRUST_OK=1 service_pid={service_pid} project_roots={len(worker_pids)} "
    f"analyzer_descendants={len(analyzers_seen)} max_depth={trust['tree_summary']['maximum_depth']} "
    f"progress={trust['progress_baseline']}"
)
PY
