#!/usr/bin/env bash
set -euo pipefail

ROOT=${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"

[ -s "$A_PID_FILE" ] && [ -s "$A_START_FILE" ] || { echo "A_HEALTHY=0 reason=identity_missing"; exit 1; }
pid=$(cat "$A_PID_FILE")
expected_start=$(cat "$A_START_FILE")
kill -0 "$pid" 2>/dev/null || { echo "A_HEALTHY=0 reason=not_running pid=$pid"; exit 1; }
actual_start=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
[ "$actual_start" = "$expected_start" ] || { echo "A_HEALTHY=0 reason=identity_changed pid=$pid"; exit 1; }

lock_path=
for candidate in "$STATE_PATH.lock.info" "$(dirname "$STATE_PATH")/.$(basename "$STATE_PATH").lock.info"; do
  if [ -s "$candidate" ]; then lock_path=$candidate; break; fi
done
[ -n "$lock_path" ] || { echo "A_HEALTHY=0 reason=lock_missing pid=$pid"; exit 1; }
chgrp "$STATE_GROUP" "$lock_path" 2>/dev/null || true
chmod 640 "$lock_path" 2>/dev/null || true

[ -s "$A_PROGRESS_FILE" ] || { echo "A_HEALTHY=0 reason=progress_missing pid=$pid"; exit 1; }

python3 - "$A_PROGRESS_FILE" "$lock_path" "$pid" "$A_RUN_ID" <<'PY'
import json
import pathlib
import sys
import time

progress = json.loads(pathlib.Path(sys.argv[1]).read_text())
lock = json.loads(pathlib.Path(sys.argv[2]).read_text())
phase = str(progress.get("phase", ""))
age = time.time() - float(progress.get("updated_at", 0))
ok = (
    phase in {
        "runner_image_pinned",
        "capacity_plan_rendered",
        "artifact_cache_warmed",
        "matrix_smoke_passed",
        "output_commit_pending",
    }
    and age < 12.0
    and progress.get("run_id") == sys.argv[4]
    and bool(lock.get("ID"))
    and "Apply" in str(lock.get("Operation", ""))
)
print(
    f"A_HEALTHY={int(ok)} pid={sys.argv[3]} phase={phase} "
    f"step={progress.get('step')}/{progress.get('steps')} progress_age={age:.3f} "
    f"lock_id={lock.get('ID')} lock_path={sys.argv[2]}"
)
raise SystemExit(0 if ok else 1)
PY
