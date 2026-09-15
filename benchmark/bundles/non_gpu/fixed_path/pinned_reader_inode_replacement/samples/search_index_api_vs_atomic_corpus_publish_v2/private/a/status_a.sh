#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
set -a
. "$PRIVATE_ROOT/fixture.env"
set +a

python3 - <<'PY'
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

host = os.environ["SERVICE_HOST"]
port = os.environ["SERVICE_PORT"]
dataset = os.environ["A_DATASET_ID"]
primary = os.environ["A_TERM_PRIMARY"]
retired = os.environ["A_TERM_RETIRED"]
pid_file = pathlib.Path(os.environ["A_PID_FILE"])
status_file = pathlib.Path(os.environ["A_STATUS_FILE"])

if not pid_file.exists():
    print("A_STATUS_OK=0 REASON=pid_missing")
    sys.exit(1)
pid = int(pid_file.read_text().strip())
if not pathlib.Path(f"/proc/{pid}").exists():
    print(f"A_STATUS_OK=0 REASON=process_missing PID={pid}")
    sys.exit(1)

def get(path):
    with urllib.request.urlopen(f"http://{host}:{port}{path}", timeout=1.0) as response:
        return json.loads(response.read().decode("utf-8"))

try:
    health = get("/health")
    q_primary = get(f"/query?q={primary}")
    q_retired = get(f"/query?q={retired}")
except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
    print(f"A_STATUS_OK=0 REASON=http_failed ERROR={type(exc).__name__}:{exc}")
    sys.exit(1)

reasons = []
if health.get("pid") != pid:
    reasons.append("pid_mismatch")
if health.get("dataset_id") != dataset:
    reasons.append("dataset_mismatch")
if not health.get("health"):
    reasons.append("health_false")
if q_primary.get("dataset_id") != dataset or not q_primary.get("ok"):
    reasons.append("primary_query_failed")
if q_retired.get("dataset_id") != dataset or not q_retired.get("ok"):
    reasons.append("retired_query_failed")
if not status_file.exists():
    reasons.append("status_file_missing")

if reasons:
    print(f"A_STATUS_OK=0 PID={pid} REASONS={','.join(reasons)}")
    sys.exit(1)
print(
    f"A_STATUS_OK=1 PID={pid} DATASET={dataset} "
    f"FD_INODE={health.get('fd_inode')} CANONICAL_INODE={(health.get('canonical') or {}).get('inode')}"
)
PY

