#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}}
source "$ROOT/fixture.env"

python3 - "$PID_FILE" "$HEALTH_PATH" "$CANONICAL_PATH" "$A_PUBLISHER" "$A_SCHEMA" <<'PY'
from __future__ import annotations

import hashlib
import json
import pathlib
import sys

pid_file = pathlib.Path(sys.argv[1])
health_path = pathlib.Path(sys.argv[2])
canonical = pathlib.Path(sys.argv[3])
publisher = sys.argv[4]
schema = sys.argv[5]

if not pid_file.exists():
    print("A_STATUS_OK=0 reason=no_pid_file")
    raise SystemExit(1)
pid = int(pid_file.read_text().strip())
proc = pathlib.Path(f"/proc/{pid}")
if not proc.exists():
    print(f"A_STATUS_OK=0 pid={pid} reason=dead")
    raise SystemExit(1)
if not health_path.exists():
    print(f"A_STATUS_OK=0 pid={pid} reason=no_health")
    raise SystemExit(1)
if not canonical.exists():
    print(f"A_STATUS_OK=0 pid={pid} reason=no_canonical_snapshot")
    raise SystemExit(1)

health = json.loads(health_path.read_text())
snap = json.loads(canonical.read_text())
if health.get("healthy") is not True:
    print(f"A_STATUS_OK=0 pid={pid} reason=unhealthy detail={health.get('last_error', '')}")
    raise SystemExit(1)
if health.get("output_path") != str(canonical):
    print(f"A_STATUS_OK=0 pid={pid} reason=wrong_output_path output={health.get('output_path')}")
    raise SystemExit(1)
if snap.get("schema_version") != schema or snap.get("publisher") != publisher:
    print(
        "A_STATUS_OK=0 "
        f"pid={pid} reason=wrong_snapshot publisher={snap.get('publisher')} schema={snap.get('schema_version')}"
    )
    raise SystemExit(1)
if not (health.get("canary") or {}).get("ok"):
    print(f"A_STATUS_OK=0 pid={pid} reason=canary_failed")
    raise SystemExit(1)

fields = (proc / "stat").read_text().split()
start_ticks = fields[21] if len(fields) > 21 else "unknown"
st = canonical.stat()
digest = hashlib.sha256(canonical.read_bytes()).hexdigest()
print(
    "A_STATUS_OK=1 "
    f"pid={pid} "
    f"start_ticks={start_ticks} "
    f"publish_count={health.get('publish_count')} "
    f"source_revision={health.get('source_revision')} "
    f"inode={st.st_ino} "
    f"digest={digest} "
    f"canary_ok=1"
)
PY
