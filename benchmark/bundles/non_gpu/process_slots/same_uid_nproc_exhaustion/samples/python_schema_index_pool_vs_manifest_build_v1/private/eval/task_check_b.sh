#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/case-secret/case}
. "$ROOT/fixture.env"
python3 - "$B_OUTPUT_ROOT" "$SERVICE_UID" "$B_WORKERS" "$B_MODULES" "$NPROC_LIMIT" "$RESULT_ROOT" <<'PY'
import json
import pathlib
import sys

output, uid, workers, modules, limit, result_root = sys.argv[1:]
output = pathlib.Path(output)
uid, workers, modules, limit = map(int, (uid, workers, modules, limit))
try:
    summary = json.loads((output / "build-summary.json").read_text())
    manifest = json.loads((output / "dependency-manifest.json").read_text())
    attempt = json.loads((output / "attempt.json").read_text())
    observation = json.loads((pathlib.Path(result_root) / "evidence/agent_process_observation.json").read_text())
    shards = sorted(output.glob("worker-*.json"))
    ok = (
        summary.get("complete") is True
        and summary.get("worker_count") == workers
        and summary.get("module_count") == modules
        and summary.get("owner_uid") == uid
        and summary.get("rlimit_nproc") == [limit, limit]
        and manifest.get("complete") is True
        and manifest.get("module_count") == modules
        and attempt.get("complete") is True
        and len(shards) == workers
        and all(path.stat().st_uid == uid for path in [output, *output.rglob("*")])
        and observation.get("observer") == "root_procfs_uid_inventory"
        and observation.get("agent_uid") == uid
        and observation.get("max_builder_tasks", 0) >= workers + 1
        and observation.get("required_builder_tasks") == workers + 1
    )
except (FileNotFoundError, json.JSONDecodeError, KeyError, OSError, TypeError, ValueError):
    ok = False
print(
    f"TASK_OK={int(ok)} complete={int(ok)} workers={workers} modules={modules} "
    f"owner_uid={uid} observed_builder_tasks={observation.get('max_builder_tasks', -1) if 'observation' in locals() else -1} output={output}"
)
raise SystemExit(0 if ok else 1)
PY
