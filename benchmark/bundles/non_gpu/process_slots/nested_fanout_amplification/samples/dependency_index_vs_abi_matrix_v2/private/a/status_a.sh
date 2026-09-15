#!/usr/bin/env bash
set -euo pipefail

. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$A_RUNTIME_ROOT" "$A_PROJECT_WORKERS" "$A_ANALYZERS_PER_WORKER" <<'PY'
import json
from pathlib import Path
import sys
import time

root = Path(sys.argv[1])
projects = int(sys.argv[2])
analyzers = int(sys.argv[3])
health_path = root / "health.json"
if not health_path.is_file() or time.time() - health_path.stat().st_mtime > 3:
    raise SystemExit(1)
health = json.loads(health_path.read_text())
if not health.get("healthy"):
    raise SystemExit(1)
if health.get("configured_projects") != projects or health.get("configured_analyzers_per_project") != analyzers:
    raise SystemExit(1)
if len(health.get("project_workers", [])) != projects or health.get("phase_projects") != projects:
    raise SystemExit(1)
if int(health.get("active_analyzers", 0)) < projects * analyzers - projects:
    raise SystemExit(1)
for pid in [health["service_pid"], *health["project_workers"]]:
    stat = Path(f"/proc/{pid}/stat")
    if not stat.is_file() or stat.read_text().split()[2] == "Z":
        raise SystemExit(1)
print(
    f"INDEX_SERVICE_HEALTHY=1 pid={health['service_pid']} projects={projects} "
    f"active_analyzers={health['active_analyzers']} progress={health['completed_generations']}"
)
PY
