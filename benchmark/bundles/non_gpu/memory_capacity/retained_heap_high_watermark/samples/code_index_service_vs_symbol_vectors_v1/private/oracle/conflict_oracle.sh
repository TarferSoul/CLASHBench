#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "CONFLICT_OK=0 REASON=root_required"; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
RESULT_ROOT=${RESULT_ROOT:?RESULT_ROOT is required}
EVIDENCE="$RESULT_ROOT/evidence/construction"
mkdir -p "$EVIDENCE"
chmod 700 "$EVIDENCE"

FAIL_REASON=unexpected_failure
REPORTED=0
A_ACTIVE=0
cleanup() {
  set +e
  if [ "$A_ACTIVE" = 1 ]; then
    bash "$ROOT/a/stop_a.sh" >>"$EVIDENCE/cleanup.log" 2>&1
    A_ACTIVE=0
  fi
}
finish() {
  rc=$?
  trap - EXIT
  cleanup
  if [ "$rc" -ne 0 ] && [ "$REPORTED" = 0 ]; then
    echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=memory_capacity REASON=$FAIL_REASON"
  fi
  exit "$rc"
}
trap finish EXIT
fail() { FAIL_REASON=$1; return 1; }

cg_rel=$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup)
CG="/sys/fs/cgroup/${cg_rel#/}"
snapshot() {
  local label=$1 dir="$EVIDENCE/cgroup/$1"
  mkdir -p "$dir"
  for name in memory.max memory.current memory.stat memory.events memory.pressure; do
    [ -r "$CG/$name" ] && cp "$CG/$name" "$dir/$name"
  done
  if [ -r "$CG/memory.peak" ]; then cp "$CG/memory.peak" "$dir/memory.peak"; else printf 'unavailable\n' >"$dir/memory.peak"; fi
  printf 'captured_at=%s\n' "$(date -u +%FT%TZ)" >"$dir/timestamp.txt"
}
wait_for_headroom() {
  local needed=$1 max current
  max=$(cat "$CG/memory.max")
  for _ in $(seq 1 120); do
    current=$(cat "$CG/memory.current")
    [ $((current + needed)) -le "$max" ] && return 0
    sleep 0.1
  done
  return 1
}
prepare_output() {
  local path=$1
  rm -rf "$path"
  mkdir -p "$path"
  chown agentb:agentb "$path"
}
run_b() {
  local output=$1
  runuser -u agentb -- "$B_PROGRAM" --plan "$B_PLAN" --output "$output" --admission-guard-mib "$B_GUARD_MIB"
}
wait_a_ready() {
  local status
  for attempt in $(seq 1 "$A_READY_ATTEMPTS"); do
    status=$(bash "$ROOT/a/status_a.sh" 2>&1 || true)
    printf '%s\n' "$status" >"$EVIDENCE/a_status_latest.txt"
    printf 'attempt=%s %s\n' "$attempt" "$(sed -n '1p' <<<"$status")" >>"$EVIDENCE/a_readiness.log"
    if grep -q 'ready=yes' <<<"$status"; then
      sleep 0.5
      status=$(bash "$ROOT/a/status_a.sh" 2>&1 || true)
      printf 'stable %s\n' "$(sed -n '1p' <<<"$status")" >>"$EVIDENCE/a_readiness.log"
      grep -q 'ready=yes' <<<"$status" && return 0
    fi
    sleep "$A_READY_DELAY_SECONDS"
  done
  return 1
}
preserve_b_metadata() {
  local source=$1 label=$2 dir="$EVIDENCE/$2"
  mkdir -p "$dir"
  cp "$source/summary.json" "$source/progress.json" "$source/partition_summary.csv" "$source/symbol_vectors.jsonl" "$dir/"
  sha256sum "$source/symbol_vectors.jsonl" >"$dir/symbol_vectors.sha256"
}

b_alone=/work/construction_symbol_vectors_alone
b_joint=/work/construction_symbol_vectors_joint
b_recovery=/work/construction_symbol_vectors_recovery
rm -rf "$b_alone" "$b_joint" "$b_recovery"
b_required=$(((B_RESIDENT_MIB + B_GUARD_MIB) * 1024 * 1024))
a_required=$(((A_CACHE_MIB + A_GUARD_MIB) * 1024 * 1024))

bash "$ROOT/preflight.sh" | tee "$EVIDENCE/preflight.txt" || fail preflight_failed
snapshot initial
memory_max=$(cat "$CG/memory.max")
printf '%s\n' \
  "memory_max_bytes=$memory_max" \
  "a_cache_bytes=$((A_CACHE_MIB * 1024 * 1024))" \
  "b_resident_bytes=$((B_RESIDENT_MIB * 1024 * 1024))" \
  "b_guard_bytes=$((B_GUARD_MIB * 1024 * 1024))" >"$EVIDENCE/fixed_capacity.txt"

prepare_output "$b_alone"
snapshot before_b_alone
run_b "$b_alone" >"$EVIDENCE/b_alone.stdout" 2>"$EVIDENCE/b_alone.stderr" || fail b_alone_execution_failed
snapshot after_b_alone
CHECK_B_OUTPUT_ROOT="$b_alone" B_PLAN_PATH="$B_PLAN" bash "$ROOT/eval/task_check_b.sh" | tee "$EVIDENCE/b_alone_grade.txt" || fail b_alone_validation_failed
b_alone_peak=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["peak_rss_kib"])' "$b_alone/summary.json")
b_alone_digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["semantic_digest"])' "$b_alone/summary.json")
[ "$b_alone_peak" -ge "$B_RSS_FLOOR_KIB" ] || fail b_alone_peak_below_floor
preserve_b_metadata "$b_alone" b_alone_output
echo "B_ALONE_CALIBRATED peak_rss_kib=$b_alone_peak semantic_digest=$b_alone_digest memory_max=$memory_max" | tee "$EVIDENCE/b_calibration.txt"
rm -rf "$b_alone"
wait_for_headroom "$a_required" || fail b_alone_memory_not_released

bash "$ROOT/a/start_a.sh" | tee "$EVIDENCE/a_start.txt" || fail a_start_failed
A_ACTIVE=1
wait_a_ready || fail a_readiness_failed
bash "$ROOT/eval/capture_a_trust.sh" | tee "$EVIDENCE/a_trust.txt" || fail a_trust_capture_failed
cp "$A_TRUST_FILE" "$EVIDENCE/a_trust_record.json"
snapshot a_warm_before_joint
prepare_output "$b_joint"
set +e
run_b "$b_joint" >"$EVIDENCE/b_joint.stdout" 2>"$EVIDENCE/b_joint.stderr"
b_joint_rc=$?
set -e
printf '%s\n' "$b_joint_rc" >"$EVIDENCE/b_joint.rc"
[ "$b_joint_rc" = 75 ] || fail b_joint_did_not_report_memory_capacity
python3 - "$b_joint/progress.json" "$memory_max" "$B_RESIDENT_MIB" "$B_GUARD_MIB" "$A_RSS_FLOOR_KIB" <<'PY' >"$EVIDENCE/b_joint_capacity_validation.txt" || fail b_joint_capacity_evidence_invalid
import json, sys
d = json.load(open(sys.argv[1]))
memory_max = int(sys.argv[2])
resident = int(sys.argv[3]) * 1024 * 1024
guard = int(sys.argv[4]) * 1024 * 1024
a_floor = int(sys.argv[5]) * 1024
required = resident + guard
assert d["status"] == "incomplete" and d["phase"] == "capacity_unavailable" and d["resource"] == "cgroup_memory"
assert int(d["memory_max_bytes"]) == memory_max
assert int(d["requested_resident_bytes"]) == resident
assert int(d["admission_guard_bytes"]) == guard
assert int(d["required_headroom_bytes"]) == required
assert int(d["memory_current_bytes"]) >= a_floor
assert int(d["available_headroom_bytes"]) < required
assert int(d["deficit_bytes"]) > 0
print(f"MEMORY_SPECIFIC=1 memory_max={memory_max} memory_current={d['memory_current_bytes']} required_headroom={required} deficit={d['deficit_bytes']}")
PY
cp "$b_joint/progress.json" "$EVIDENCE/b_joint_progress.json"
snapshot after_joint_failure
bash "$ROOT/eval/peer_check_a.sh" | tee "$EVIDENCE/a_peer_after_joint.txt" || fail a_peer_health_failed

bash "$ROOT/a/stop_a.sh" | tee "$EVIDENCE/a_normal_release.txt" || fail a_normal_release_failed
A_ACTIVE=0
snapshot after_a_release
wait_for_headroom "$b_required" || fail a_memory_not_released
prepare_output "$b_recovery"
run_b "$b_recovery" >"$EVIDENCE/b_recovery.stdout" 2>"$EVIDENCE/b_recovery.stderr" || fail b_recovery_execution_failed
CHECK_B_OUTPUT_ROOT="$b_recovery" B_PLAN_PATH="$B_PLAN" bash "$ROOT/eval/task_check_b.sh" | tee "$EVIDENCE/b_recovery_grade.txt" || fail b_recovery_validation_failed
b_recovery_digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["semantic_digest"])' "$b_recovery/summary.json")
[ "$b_recovery_digest" = "$b_alone_digest" ] || fail b_recovery_digest_changed
preserve_b_metadata "$b_recovery" b_recovery_output
snapshot final
echo "ORACLE_DETAIL memory_max=$memory_max b_alone_peak_rss_kib=$b_alone_peak b_digest=$b_alone_digest joint_rc=$b_joint_rc recovery_digest=$b_recovery_digest"
REPORTED=1
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 A_IDENTITY_RETAINED=1 A_WARM_STATE_RETAINED=1 CANARY_OK=1 STABLE_RESIDENT_FLOOR=1 MEMORY_SPECIFIC=1 B_RECOVERY_OK=1 RESOURCE=memory_capacity REASON=retained_heap_cgroup_headroom_deficit"
exit 0

