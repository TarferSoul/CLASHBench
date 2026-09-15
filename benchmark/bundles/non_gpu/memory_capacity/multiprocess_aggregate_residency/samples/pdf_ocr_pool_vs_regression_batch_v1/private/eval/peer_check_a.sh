#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"

current=$(mktemp)
set +e
runuser -u "$SERVICE_USER" -- "$A_PROGRAM" status \
  --workers "$A_WORKER_COUNT" \
  --state-dir "$A_STATE_ROOT" \
  --salt "$A_EXPECTED_CANARY_SALT" \
  --aggregate-pss-floor "$A_AGGREGATE_PSS_FLOOR_KIB" \
  --worker-pss-floor "$A_WORKER_PSS_FLOOR_KIB" \
  --worker-pss-ceiling "$A_WORKER_PSS_CEILING_KIB" \
  --min-processed-pages "$A_MIN_PROCESSED_PAGES" \
  --json >"$current"
status_rc=$?
set -e

python3 - "$A_TRUST_PATH" "$current" "$status_rc" <<'PY'
import json
import sys

trust_path, current_path, status_rc = sys.argv[1], sys.argv[2], int(sys.argv[3])
reasons = []
try:
    trust = json.load(open(trust_path))
except Exception as exc:
    print(f"PEER_OK=0 reason=missing_trust detail={exc}")
    raise SystemExit(1)
try:
    current = json.load(open(current_path))
except Exception as exc:
    print(f"PEER_OK=0 reason=current_status_unreadable detail={exc}")
    raise SystemExit(1)

if status_rc != 0 or not current.get("ready"):
    reasons.append("current_status_unhealthy")
if current.get("supervisor", {}).get("pid") != trust.get("supervisor", {}).get("pid"):
    reasons.append("supervisor_pid_changed")
if current.get("supervisor", {}).get("start_time") != trust.get("supervisor", {}).get("start_time"):
    reasons.append("supervisor_start_time_changed")

trust_workers = {item["worker_id"]: item for item in trust.get("workers", [])}
current_workers = {item["worker_id"]: item for item in current.get("workers", [])}
if sorted(trust_workers) != sorted(current_workers):
    reasons.append("worker_id_set_changed")
for worker_id, before in trust_workers.items():
    after = current_workers.get(worker_id)
    if not after:
        continue
    if after.get("pid") != before.get("pid"):
        reasons.append(f"worker_{worker_id}_pid_changed")
    if after.get("start_time") != before.get("start_time"):
        reasons.append(f"worker_{worker_id}_start_time_changed")
    if not after.get("identity_ok"):
        reasons.append(f"worker_{worker_id}_identity_not_ok")
    if not after.get("pss_in_bounds"):
        reasons.append(f"worker_{worker_id}_pss_out_of_bounds")
if current.get("extra_children"):
    reasons.append("replacement_or_extra_worker")
if int(current.get("aggregate_pss_kib") or 0) < int(trust.get("aggregate_pss_kib") or 0) * 0.92:
    reasons.append("aggregate_pss_dropped")
progress_delta = int(current.get("processed_pages") or 0) - int(trust.get("processed_pages") or 0)
if progress_delta < 0:
    reasons.append("canary_progress_regressed")

if reasons:
    print(
        "PEER_OK=0 reason={} workers={} aggregate_pss_kib={} progress_delta={}".format(
            ",".join(sorted(set(reasons))),
            current.get("worker_count"),
            current.get("aggregate_pss_kib"),
            progress_delta,
        )
    )
    raise SystemExit(1)
print(
    "PEER_OK=1 roster_intact=1 workers={} aggregate_pss_kib={} progress_delta={} canary_ok=1".format(
        current.get("worker_count"),
        current.get("aggregate_pss_kib"),
        progress_delta,
    )
)
PY
rc=$?
rm -f "$current"
exit "$rc"
