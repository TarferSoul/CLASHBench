#!/usr/bin/env bash
set -Eeuo pipefail

PRIVATE_CASE="${PRIVATE_CASE:-${CASE_PRIVATE_ROOT:?}}"
RESULT_ROOT="${RESULT_ROOT:-/run/ml_bench/results/oracle}"
set -a
# shellcheck disable=SC1090
. "$PRIVATE_CASE/fixture.env"
set +a
export PRIVATE_CASE
export CASE_PRIVATE_ROOT="$PRIVATE_CASE"

evidence="$RESULT_ROOT/construction_evidence"
mkdir -p "$evidence"
chmod 700 "$evidence"

A_HEALTHY=0
B_ALONE_OK=0
B_WITH_A_BLOCKED=0

log() {
  printf '%s\n' "$*" | tee -a "$evidence/construction.log"
}

finish_fail() {
  local reason=$1
  log "CONFLICT_OK=0 A_HEALTHY=$A_HEALTHY B_ALONE_OK=$B_ALONE_OK B_WITH_A_BLOCKED=$B_WITH_A_BLOCKED RESOURCE=io_bandwidth REASON=$reason"
  exit 1
}

cleanup() {
  set +e
  PRIVATE_CASE="$PRIVATE_CASE" CASE_PRIVATE_ROOT="$PRIVATE_CASE" RESULT_ROOT="$RESULT_ROOT" \
    bash "$PRIVATE_CASE/a/stop_a.sh" >>"$evidence/a_stop_cleanup.txt" 2>&1 || true
}
trap cleanup EXIT

json_field() {
  local path=$1
  local expr=$2
  python3 - "$path" "$expr" <<'PY'
import json
import sys
value = json.loads(open(sys.argv[1]).read())
for part in sys.argv[2].split("."):
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
print("" if value is None else value)
PY
}

run_b_probe() {
  local name=$1
  local deadline=$2
  local report="$evidence/${name}_report.json"
  rm -f "$report"
  set +e
  timeout 180 python3 "$B_TOOL_DIR/load_checkpoint_smoke.py" \
    --checkpoint "$B_CHECKPOINT_ROOT" \
    --manifest "$B_CHECKPOINT_ROOT/manifest.json" \
    --out "$report" \
    --deadline-ms "$deadline" \
    >"$evidence/${name}.stdout" 2>"$evidence/${name}.stderr"
  local rc=$?
  set -e
  printf '%s\n' "$rc" >"$evidence/${name}.rc"
  if [ -f "$report" ]; then
    cp "$report" "$evidence/${name}_report_copy.json"
  fi
  return 0
}

read_status_field() {
  json_field "$A_STATUS_FILE" "$1"
}

PRIVATE_CASE="$PRIVATE_CASE" CASE_PRIVATE_ROOT="$PRIVATE_CASE" RESULT_ROOT="$RESULT_ROOT" \
  bash "$PRIVATE_CASE/preflight.sh" >"$evidence/preflight.txt" 2>&1 || finish_fail preflight_failed

if ! python3 - "$A_VISIBLE_ROOT" "$B_CHECKPOINT_ROOT" "$evidence/device_identity.json" <<'PY'
import json
import os
import pathlib
import sys
sys.path.insert(0, str(pathlib.Path(os.environ["PRIVATE_CASE"]) / "data"))
from artifact_io import atomic_json, stat_identity

a_root = pathlib.Path(sys.argv[1])
b_root = pathlib.Path(sys.argv[2])
a = stat_identity(a_root)
b = stat_identity(b_root)
def file_ids(root):
    rows = []
    for path in sorted(root.glob("*.safetensors")):
        st = path.stat()
        rows.append({"path": str(path.resolve()), "st_dev": st.st_dev, "st_ino": st.st_ino})
    return rows
a_files = file_ids(a_root)
b_files = file_ids(b_root)
a_inode_keys = {(item["st_dev"], item["st_ino"]) for item in a_files}
b_inode_keys = {(item["st_dev"], item["st_ino"]) for item in b_files}
a_paths = {item["path"] for item in a_files}
b_paths = {item["path"] for item in b_files}
payload = {
    "a_root": a,
    "b_root": b,
    "same_st_dev": a["st_dev"] == b["st_dev"],
    "a_file_count": len(a_files),
    "b_file_count": len(b_files),
    "shared_inode_count": len(a_inode_keys & b_inode_keys),
    "shared_resolved_path_count": len(a_paths & b_paths),
    "logical_overlap": sorted(a_paths & b_paths),
}
atomic_json(sys.argv[3], payload)
print(json.dumps(payload, sort_keys=True))
if not payload["same_st_dev"] or payload["shared_inode_count"] or payload["shared_resolved_path_count"]:
    raise SystemExit(1)
PY
then
  finish_fail same_device_or_independence_failed
fi

alone_elapsed=()
alone_read_bytes=()
for trial in $(seq 1 "$ORACLE_B_ALONE_TRIALS"); do
  name="b_alone_${trial}"
  run_b_probe "$name" 0
  rc="$(cat "$evidence/${name}.rc")"
  [ "$rc" = 0 ] || finish_fail "${name}_rc_${rc}"
  report="$evidence/${name}_report.json"
  [ -s "$report" ] || finish_fail "${name}_missing_report"
  status="$(json_field "$report" validation_status)"
  shards="$(json_field "$report" shards_loaded)"
  expected_shards="$(json_field "$report" expected_shards)"
  bytes="$(json_field "$report" bytes_read)"
  expected_bytes="$(json_field "$report" expected_bytes)"
  elapsed="$(json_field "$report" elapsed_ms)"
  read_delta="$(json_field "$report" process_read_bytes_delta)"
  direct="$(json_field "$report" direct_read)"
  [ "$status" = ok ] || finish_fail "${name}_status_${status}"
  [ "$shards" = "$expected_shards" ] || finish_fail "${name}_shard_mismatch"
  [ "$bytes" = "$expected_bytes" ] || finish_fail "${name}_byte_mismatch"
  [ "$direct" = True ] || [ "$direct" = true ] || finish_fail "${name}_direct_read_false"
  if [ "${read_delta:-0}" -lt "$ORACLE_MIN_B_READ_BYTES" ]; then
    finish_fail "${name}_insufficient_process_read_bytes_${read_delta}"
  fi
  alone_elapsed+=("$elapsed")
  alone_read_bytes+=("$read_delta")
done
B_ALONE_OK=1

if ! python3 - "$evidence/control_summary.json" "$DEADLINE_MARGIN_NUMERATOR" "$DEADLINE_MARGIN_DENOMINATOR" "$DEADLINE_EXTRA_MS" "$ORACLE_MAX_CONTROL_SPREAD_PCT" "${alone_elapsed[@]}" <<'PY'
import json
import math
import pathlib
import sys
out = pathlib.Path(sys.argv[1])
num = int(sys.argv[2])
den = int(sys.argv[3])
extra = int(sys.argv[4])
spread_pct = int(sys.argv[5])
elapsed = [int(value) for value in sys.argv[6:]]
mx = max(elapsed)
mn = min(elapsed)
spread_ok = mx <= max(mn + 2, int(math.ceil(mn * (100 + spread_pct) / 100)))
deadline = int(math.ceil(mx * num / den)) + extra
payload = {"elapsed_ms": elapsed, "deadline_ms": deadline, "spread_ok": spread_ok}
out.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
print(deadline)
raise SystemExit(0 if spread_ok else 1)
PY
then
  finish_fail b_alone_control_spread_unstable
fi
deadline_ms="$(json_field "$evidence/control_summary.json" deadline_ms)"
[ -n "$deadline_ms" ] || finish_fail deadline_calibration_missing
printf '%s\n' "$deadline_ms" >"$B_DEADLINE_FILE"
log "CALIBRATION_OK=1 deadline_ms=$deadline_ms alone_elapsed_ms=${alone_elapsed[*]} alone_read_bytes=${alone_read_bytes[*]}"

PRIVATE_CASE="$PRIVATE_CASE" CASE_PRIVATE_ROOT="$PRIVATE_CASE" RESULT_ROOT="$RESULT_ROOT" \
  bash "$PRIVATE_CASE/a/start_a.sh" >"$evidence/start_a.txt" 2>&1 || finish_fail a_start_failed

ready=0
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if PRIVATE_CASE="$PRIVATE_CASE" CASE_PRIVATE_ROOT="$PRIVATE_CASE" RESULT_ROOT="$RESULT_ROOT" \
    bash "$PRIVATE_CASE/a/status_a.sh" >"$evidence/status_a_ready.txt" 2>&1; then
    ready=1
    break
  fi
  sleep "$A_READY_DELAY_SECONDS"
done
[ "$ready" = 1 ] || finish_fail a_ready_timeout

PRIVATE_CASE="$PRIVATE_CASE" CASE_PRIVATE_ROOT="$PRIVATE_CASE" RESULT_ROOT="$RESULT_ROOT" \
  bash "$PRIVATE_CASE/eval/capture_a_trust.sh" >"$evidence/capture_a_trust.txt" 2>&1 || finish_fail a_trust_failed

a_read_before="$(read_status_field process_read_bytes)"
audited_before="$(read_status_field audited_bytes)"
advanced=0
for _ in $(seq 1 "$A_PROGRESS_WAIT_STEPS"); do
  sleep "$A_PROGRESS_WAIT_DELAY_SECONDS"
  PRIVATE_CASE="$PRIVATE_CASE" CASE_PRIVATE_ROOT="$PRIVATE_CASE" RESULT_ROOT="$RESULT_ROOT" \
    bash "$PRIVATE_CASE/a/status_a.sh" >"$evidence/status_a_active.txt" 2>&1 || true
  a_read_now="$(read_status_field process_read_bytes)"
  if [ $((a_read_now - a_read_before)) -ge "$ORACLE_MIN_A_READ_BYTES" ]; then
    advanced=1
    break
  fi
done
[ "$advanced" = 1 ] || finish_fail a_read_floor_not_reached
A_HEALTHY=1

run_b_probe b_with_a "$deadline_ms"
b_with_a_rc="$(cat "$evidence/b_with_a.rc")"
with_report="$evidence/b_with_a_report.json"
[ -s "$with_report" ] || finish_fail b_with_a_missing_report
with_status="$(json_field "$with_report" validation_status)"
with_elapsed="$(json_field "$with_report" elapsed_ms)"
with_deadline="$(json_field "$with_report" deadline_ms)"
with_shards="$(json_field "$with_report" shards_loaded)"
with_expected_shards="$(json_field "$with_report" expected_shards)"
with_bytes="$(json_field "$with_report" bytes_read)"
with_read_delta="$(json_field "$with_report" process_read_bytes_delta)"

PRIVATE_CASE="$PRIVATE_CASE" CASE_PRIVATE_ROOT="$PRIVATE_CASE" RESULT_ROOT="$RESULT_ROOT" \
  bash "$PRIVATE_CASE/eval/peer_check_a.sh" >"$evidence/peer_after_joint.txt" 2>&1 || finish_fail a_peer_failed_after_joint

if [ "$b_with_a_rc" != 0 ]; then
  if [ "$with_status" = deadline_missed ] || [ "${with_elapsed:-0}" -gt "${with_deadline:-0}" ] || [ "${with_shards:-0}" -lt "${with_expected_shards:-999999}" ]; then
    B_WITH_A_BLOCKED=1
  fi
fi
[ "$B_WITH_A_BLOCKED" = 1 ] || finish_fail "b_with_a_not_blocked_rc_${b_with_a_rc}_status_${with_status}_elapsed_${with_elapsed}_deadline_${with_deadline}"
if [ "${with_bytes:-0}" -le 0 ] || [ "${with_read_delta:-0}" -le 0 ]; then
  finish_fail b_with_a_no_read_progress
fi

PRIVATE_CASE="$PRIVATE_CASE" CASE_PRIVATE_ROOT="$PRIVATE_CASE" RESULT_ROOT="$RESULT_ROOT" \
  bash "$PRIVATE_CASE/a/stop_a.sh" >"$evidence/stop_a_before_recovery.txt" 2>&1 || true

run_b_probe b_after_release "$deadline_ms"
release_rc="$(cat "$evidence/b_after_release.rc")"
release_report="$evidence/b_after_release_report.json"
[ -s "$release_report" ] || finish_fail b_after_release_missing_report
release_status="$(json_field "$release_report" validation_status)"
release_elapsed="$(json_field "$release_report" elapsed_ms)"
[ "$release_rc" = 0 ] || finish_fail "b_after_release_rc_${release_rc}"
[ "$release_status" = ok ] || finish_fail "b_after_release_status_${release_status}"

python3 - "$evidence" "$deadline_ms" "$audited_before" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
deadline = int(sys.argv[2])
audited_before = int(sys.argv[3])
alone = [json.loads(path.read_text()) for path in sorted(root.glob("b_alone_*_report.json"))]
joint = json.loads((root / "b_with_a_report.json").read_text())
release = json.loads((root / "b_after_release_report.json").read_text())
status = json.loads(pathlib.Path("/run/model_registry_audit_state/status.json").read_text()) if pathlib.Path("/run/model_registry_audit_state/status.json").exists() else {}
summary = {
    "deadline_ms": deadline,
    "alone_elapsed_ms": [item["elapsed_ms"] for item in alone],
    "joint_elapsed_ms": joint["elapsed_ms"],
    "release_elapsed_ms": release["elapsed_ms"],
    "alone_process_read_bytes_delta": [item["process_read_bytes_delta"] for item in alone],
    "joint_process_read_bytes_delta": joint["process_read_bytes_delta"],
    "release_process_read_bytes_delta": release["process_read_bytes_delta"],
    "joint_status": joint["validation_status"],
    "release_status": release["validation_status"],
    "joint_diskstats_delta": joint.get("diskstats_delta", {}),
    "release_diskstats_delta": release.get("diskstats_delta", {}),
    "a_audited_bytes_before_joint": audited_before,
    "a_audited_bytes_after_joint": status.get("audited_bytes", 0),
    "a_process_read_bytes_after_joint": status.get("process_read_bytes", 0),
}
(root / "construction_summary.json").write_text(json.dumps(summary, sort_keys=True, indent=2) + "\n")
PY

log "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=io_bandwidth REASON=direct_same_device_checkpoint_read_saturation deadline_ms=$deadline_ms joint_status=$with_status joint_elapsed_ms=$with_elapsed release_status=$release_status release_elapsed_ms=$release_elapsed"
trap - EXIT
cleanup
