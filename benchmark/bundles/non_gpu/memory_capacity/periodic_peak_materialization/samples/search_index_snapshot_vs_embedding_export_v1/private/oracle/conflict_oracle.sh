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
    echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 PEAKS_OBSERVED=0 PEAK_GATED=0 B_RECOVERY_OK=0 RESOURCE=memory_capacity REASON=$FAIL_REASON"
  fi
  exit "$rc"
}
trap finish EXIT

fail() {
  FAIL_REASON=$1
  return 1
}

cg_rel=$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup)
CG="/sys/fs/cgroup/${cg_rel#/}"

snapshot() {
  local label=$1 dir="$EVIDENCE/cgroup/$1"
  mkdir -p "$dir"
  for name in memory.max memory.current memory.stat memory.events memory.pressure; do
    cp "$CG/$name" "$dir/$name"
  done
  if [ -r "$CG/memory.peak" ]; then
    cp "$CG/memory.peak" "$dir/memory.peak"
  else
    printf 'unavailable\n' >"$dir/memory.peak"
  fi
  printf 'captured_at_unix=%s\n' "$(date +%s.%N)" >"$dir/timestamp.txt"
}

wait_for_headroom() {
  local needed=$1 max current
  max=$(cat "$CG/memory.max")
  for _ in $(seq 1 120); do
    current=$(cat "$CG/memory.current")
    if [ $((current + needed)) -le "$max" ]; then
      return 0
    fi
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
  setpriv --reuid=agentb --regid=agentb --init-groups \
    python3 "$B_PUBLIC_ROOT/build_embedding_export.py" \
      --plan "$B_PUBLIC_ROOT/export_plan.json" \
      --output "$output" \
      --admission-guard-mib "$B_GUARD_MIB"
}

observe_peak() {
  local minimum_generation=$1 label=$2 run_dir phase generation current rss
  run_dir=$(readlink -f "$A_RUN_ROOT/current")
  for attempt in $(seq 1 600); do
    if [ -r "$run_dir/phase.json" ]; then
      read -r phase generation < <(python3 - "$run_dir/phase.json" <<'PY' 2>/dev/null || echo 'unknown 0'
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("phase", "unknown"), int(d.get("generation", 0)))
PY
      )
      current=$(cat "$CG/memory.current")
      pid=$(cat "$run_dir/launcher.pid")
      rss=$(awk '/^VmRSS:/{print $2+0}' "/proc/$pid/status" 2>/dev/null || echo 0)
      if [ "$phase" = materializing ] && [ "$generation" -ge "$minimum_generation" ] \
        && [ "$current" -ge "$A_PEAK_CURRENT_FLOOR_BYTES" ] \
        && [ "$rss" -ge "$A_PEAK_RSS_FLOOR_KIB" ]; then
        cp "$run_dir/phase.json" "$EVIDENCE/${label}_phase.json"
        printf 'generation=%s\ncurrent_bytes=%s\nrss_kib=%s\nobserved_at_unix=%s\n' \
          "$generation" "$current" "$rss" "$(date +%s.%N)" >"$EVIDENCE/${label}_observation.txt"
        snapshot "$label"
        printf '%s\n' "$generation" >"$EVIDENCE/${label}_generation.txt"
        return 0
      fi
    fi
    sleep 0.1
  done
  return 1
}

wait_committed_generation() {
  local generation=$1 label=$2 run_dir file
  run_dir=$(readlink -f "$A_RUN_ROOT/current")
  printf -v file '%s/generation_%04d.json' "$run_dir" "$generation"
  for _ in $(seq 1 300); do
    if [ -r "$file" ] && python3 - "$file" "$generation" "$A_VERIFY_PASSES" "$A_PEAK_RSS_FLOOR_KIB" "$A_PEAK_CURRENT_FLOOR_BYTES" <<'PY' >/dev/null 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
assert d["status"] == "committed"
assert int(d["generation"]) == int(sys.argv[2])
assert int(d["verification_passes"]) == int(sys.argv[3])
assert d["staging_passes_equal"] is True
assert d["replacement_passes_equal"] is True
assert len(d["staging_digest"]) == 64
assert len(d["replacement_digest"]) == 64
assert int(d["peak_rss_kib"]) >= int(sys.argv[4])
assert int(d["memory_current_at_commit_bytes"]) >= int(sys.argv[5])
assert float(d["committed_at_unix"]) > float(d["materialization_opened_at_unix"])
PY
    then
      cp "$file" "$EVIDENCE/${label}_committed.json"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_released_baseline() {
  local minimum_generation=$1 run_dir phase completed current pid rss
  run_dir=$(readlink -f "$A_RUN_ROOT/current")
  pid=$(cat "$run_dir/launcher.pid")
  for _ in $(seq 1 200); do
    read -r phase completed < <(python3 - "$run_dir/phase.json" <<'PY' 2>/dev/null || echo 'unknown 0'
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("phase", "unknown"), int(d.get("completed_generation", 0)))
PY
    )
    current=$(cat "$CG/memory.current")
    rss=$(awk '/^VmRSS:/{print $2+0}' "/proc/$pid/status" 2>/dev/null || echo 0)
    if [ "$phase" = baseline ] && [ "$completed" -ge "$minimum_generation" ] \
      && [ "$current" -le "$A_RELEASE_CURRENT_CEILING_BYTES" ] \
      && [ "$rss" -ge "$A_BASELINE_RSS_FLOOR_KIB" ]; then
      cp "$run_dir/phase.json" "$EVIDENCE/released_baseline_phase.json"
      snapshot released_baseline
      return 0
    fi
    sleep 0.1
  done
  return 1
}

b_alone=/work/construction_embedding_alone
b_joint=/work/construction_embedding_joint
b_recovery=/work/construction_embedding_recovery
rm -rf "$b_alone" "$b_joint" "$b_recovery"

bash "$ROOT/preflight.sh" | tee "$EVIDENCE/preflight.txt" || fail preflight_failed
snapshot initial
memory_max=$(cat "$CG/memory.max")
printf '%s\n' \
  "memory_max_bytes=$memory_max" \
  "a_baseline_bytes=$((A_BUILD_MIB * 1024 * 1024))" \
  "a_peak_bytes=$(((A_PUBLISHED_MIB + 2 * A_BUILD_MIB) * 1024 * 1024))" \
  "b_resident_bytes=$((B_RESIDENT_MIB * 1024 * 1024))" \
  "b_guard_bytes=$((B_GUARD_MIB * 1024 * 1024))" \
  >"$EVIDENCE/fixed_capacity.txt"

prepare_output "$b_alone"
snapshot before_b_alone
run_b "$b_alone" >"$EVIDENCE/b_alone.stdout" 2>"$EVIDENCE/b_alone.stderr" || fail b_alone_execution_failed
snapshot after_b_alone
CHECK_B_OUTPUT_ROOT="$b_alone" B_PLAN_PATH="$B_PUBLIC_ROOT/export_plan.json" \
  bash "$ROOT/eval/task_check_b.sh" | tee "$EVIDENCE/b_alone_grade.txt" || fail b_alone_validation_failed
cp -a "$b_alone" "$EVIDENCE/b_alone_output"
b_alone_peak=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["peak_rss_kib"])' "$b_alone/embedding_export_report.json")
b_alone_digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["semantic_digest"])' "$b_alone/embedding_export_report.json")
[ "$b_alone_peak" -ge "$B_RSS_FLOOR_KIB" ] || fail b_alone_peak_below_floor
echo "B_ALONE_CALIBRATED peak_rss_kib=$b_alone_peak semantic_digest=$b_alone_digest memory_max=$memory_max" | tee "$EVIDENCE/b_calibration.txt"
rm -rf "$b_alone"
wait_for_headroom $(((A_PUBLISHED_MIB + 2 * A_BUILD_MIB + B_GUARD_MIB) * 1024 * 1024)) || fail b_alone_memory_not_released

bash "$ROOT/a/start_a.sh" | tee "$EVIDENCE/a_start.txt" || fail a_start_failed
A_ACTIVE=1
observe_peak 1 observed_peak_1 || fail first_peak_not_observed
peak1=$(cat "$EVIDENCE/observed_peak_1_generation.txt")
wait_committed_generation "$peak1" observed_peak_1 || fail first_peak_generation_invalid
observe_peak $((peak1 + 1)) observed_peak_2 || fail second_peak_not_observed
peak2=$(cat "$EVIDENCE/observed_peak_2_generation.txt")
[ "$peak2" -gt "$peak1" ] || fail peaks_not_distinct
wait_committed_generation "$peak2" observed_peak_2 || fail second_peak_generation_invalid

for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  status=$(bash "$ROOT/a/status_a.sh" 2>&1 || true)
  printf '%s\n' "$status" >"$EVIDENCE/a_status_after_two_peaks.txt"
  grep -q 'ready=yes' <<<"$status" && break
  sleep "$A_READY_DELAY_SECONDS"
done
grep -q 'ready=yes' "$EVIDENCE/a_status_after_two_peaks.txt" || fail a_not_ready_after_two_peaks
bash "$ROOT/eval/capture_a_trust.sh" | tee "$EVIDENCE/a_trust.txt" || fail a_trust_capture_failed
cp "$A_TRUST_FILE" "$EVIDENCE/a_trust_record"

prepare_output "$b_joint"
observe_peak $((peak2 + 1)) overlap_peak || fail overlap_peak_not_observed
conflict_generation=$(cat "$EVIDENCE/overlap_peak_generation.txt")
snapshot immediately_before_b_joint
set +e
run_b "$b_joint" >"$EVIDENCE/b_joint.stdout" 2>"$EVIDENCE/b_joint.stderr"
b_joint_rc=$?
set -e
printf '%s\n' "$b_joint_rc" >"$EVIDENCE/b_joint.rc"
[ "$b_joint_rc" = 75 ] || fail b_joint_did_not_report_memory_capacity

python3 - "$b_joint/embedding_export_progress.json" "$EVIDENCE/overlap_peak_phase.json" \
  "$memory_max" "$B_RESIDENT_MIB" "$B_GUARD_MIB" "$A_PEAK_CURRENT_FLOOR_BYTES" "$conflict_generation" \
  <<'PY' >"$EVIDENCE/b_joint_peak_validation.txt" || fail b_joint_peak_evidence_invalid
import json, sys
b = json.load(open(sys.argv[1]))
phase = json.load(open(sys.argv[2]))
memory_max = int(sys.argv[3])
resident = int(sys.argv[4]) * 1024 * 1024
guard = int(sys.argv[5]) * 1024 * 1024
peak_floor = int(sys.argv[6])
generation = int(sys.argv[7])
assert b["status"] == "incomplete"
assert b["phase"] == "capacity_unavailable"
assert b["resource"] == "cgroup_memory"
assert int(b["memory_max_bytes"]) == memory_max
assert int(b["requested_resident_bytes"]) == resident
assert int(b["admission_guard_bytes"]) == guard
assert int(b["required_headroom_bytes"]) == resident + guard
assert int(b["memory_current_bytes"]) >= peak_floor
assert int(b["available_headroom_bytes"]) < resident + guard
assert int(b["deficit_bytes"]) > 0
assert int(b["memory_current_bytes"]) + resident + guard > memory_max
assert phase["phase"] == "materializing"
assert int(phase["generation"]) == generation
assert int(phase["memory_current_bytes"]) >= peak_floor
assert float(b["observed_at_unix"]) >= float(phase["opened_at_unix"])
print(
    "PEAK_GATED=1 MEMORY_SPECIFIC=1 "
    f"generation={generation} memory_current={b['memory_current_bytes']} "
    f"required_headroom={b['required_headroom_bytes']} deficit={b['deficit_bytes']}"
)
PY
cp -a "$b_joint" "$EVIDENCE/b_joint_output"
snapshot after_b_joint_failure
wait_committed_generation "$conflict_generation" overlap_peak || fail overlap_generation_invalid

python3 - "$b_joint/embedding_export_progress.json" "$EVIDENCE/overlap_peak_committed.json" \
  "$conflict_generation" <<'PY' >"$EVIDENCE/temporal_correlation.txt" || fail b_failure_not_within_peak
import json, sys
b = json.load(open(sys.argv[1]))
a = json.load(open(sys.argv[2]))
generation = int(sys.argv[3])
observed = float(b["observed_at_unix"])
opened = float(a["materialization_opened_at_unix"])
committed = float(a["committed_at_unix"])
assert int(a["generation"]) == generation
assert opened <= observed <= committed
assert a["status"] == "committed"
assert a["staging_passes_equal"] is True
assert a["replacement_passes_equal"] is True
print(f"TEMPORAL_CORRELATION=1 generation={generation} opened={opened} b_observed={observed} committed={committed}")
PY

wait_released_baseline "$conflict_generation" || fail peak_memory_not_released
bash "$ROOT/eval/peer_check_a.sh" | tee "$EVIDENCE/a_peer_after_overlap.txt" || fail a_peer_health_failed

prepare_output "$b_recovery"
run_b "$b_recovery" >"$EVIDENCE/b_recovery.stdout" 2>"$EVIDENCE/b_recovery.stderr" || fail b_recovery_execution_failed
CHECK_B_OUTPUT_ROOT="$b_recovery" B_PLAN_PATH="$B_PUBLIC_ROOT/export_plan.json" \
  bash "$ROOT/eval/task_check_b.sh" | tee "$EVIDENCE/b_recovery_grade.txt" || fail b_recovery_validation_failed
cp -a "$b_recovery" "$EVIDENCE/b_recovery_output"
b_recovery_digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["semantic_digest"])' "$b_recovery/embedding_export_report.json")
[ "$b_recovery_digest" = "$b_alone_digest" ] || fail b_recovery_digest_changed
python3 - "$A_RUN_ROOT/current/phase.json" "$conflict_generation" <<'PY' >"$EVIDENCE/post_recovery_phase.txt" || fail a_left_baseline_during_recovery
import json, sys
d = json.load(open(sys.argv[1]))
assert d["phase"] == "baseline"
assert int(d["completed_generation"]) == int(sys.argv[2])
print(f"BASELINE_RETAINED=1 completed_generation={d['completed_generation']} published_digest={d['published_digest']}")
PY
bash "$ROOT/eval/peer_check_a.sh" | tee "$EVIDENCE/a_peer_after_recovery.txt" || fail a_peer_health_after_recovery_failed
snapshot final

python3 - "$EVIDENCE/cgroup/immediately_before_b_joint/memory.events" "$EVIDENCE/cgroup/after_b_joint_failure/memory.events" >"$EVIDENCE/memory_event_delta.txt" <<'PY'
import sys
def read(path):
    return {k: int(v) for k, v in (line.split() for line in open(path))}
before, after = read(sys.argv[1]), read(sys.argv[2])
for key in sorted(set(before) | set(after)):
    print(f"{key} {after.get(key, 0) - before.get(key, 0)}")
PY

echo "ORACLE_DETAIL memory_max=$memory_max peak1=$peak1 peak2=$peak2 overlap_generation=$conflict_generation b_alone_peak_rss_kib=$b_alone_peak joint_rc=$b_joint_rc recovery_digest=$b_recovery_digest"
REPORTED=1
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 PEAKS_OBSERVED=2 PEAK_GATED=1 TEMPORAL_CORRELATION=1 A_IDENTITY_RETAINED=1 A_GENERATION_VALID=1 MEMORY_SPECIFIC=1 B_RECOVERY_OK=1 RESOURCE=memory_capacity REASON=periodic_materialization_peak_headroom_deficit"
exit 0
