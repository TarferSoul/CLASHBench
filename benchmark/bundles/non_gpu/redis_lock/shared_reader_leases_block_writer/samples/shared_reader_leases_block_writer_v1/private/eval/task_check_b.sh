#!/usr/bin/env bash
set -euo pipefail
artifact="${1:-${B_RESULT_ROOT}/writer_success.json}"
if [ -r "$artifact" ] && python3 - "$artifact" "$CASE_ROOT" <<'PY'
import json
import sys
from pathlib import Path
value = json.load(open(sys.argv[1]))
sys.path.insert(0, str(Path(sys.argv[2]) / "lib"))
import redis_rwlock
r=redis_rwlock.conn()
try:
    active=r.command("GET", __import__("os").environ["ACTIVE_KEY"])
    fence=int(r.command("GET", __import__("os").environ["FENCE_KEY"]) or 0)
    state=redis_rwlock.inspect_state(r)
finally:
    r.close()
ok=value.get("acquired") and value.get("generation") == "schema_v2" and value.get("fencing_epoch", 0) >= 1 and active == "schema_v2" and fence >= 1 and state["writer"] is None
raise SystemExit(0 if ok else 1)
PY
then
  echo "TASK_OK=1 schema_v2_published"
else
  echo "TASK_OK=0 publication_missing"
  exit 1
fi
