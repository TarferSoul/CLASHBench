#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
. "$CASE_PRIVATE_ROOT/data/volume_lib.sh"

a_active=0
oracle_cleanup() {
  set +e
  if [ "$a_active" = 1 ]; then
    CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" force \
      >"$RESULT_ROOT/evidence/oracle_cleanup_a.txt" 2>&1 || true
  fi
  set -e
}
trap oracle_cleanup EXIT

fail() {
  printf 'CONFLICT_OK=0 A_HEALTHY=%s B_ALONE_OK=%s B_WITH_A_BLOCKED=%s RESOURCE=disk_space REASON=%s\n' \
    "${a_healthy:-0}" "${b_alone_ok:-0}" "${b_blocked:-0}" "$1"
  exit 1
}

run_b_monitored() {
  local label=$1 before min_free current state bpid
  before=$(volume_free_bytes)
  min_free=$before
  agent_uid=$(id -u agentb)
  agent_gid=$(id -g agentb)
  setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups -- \
    env -i HOME=/home/agentb USER=agentb LOGNAME=agentb \
    PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
    "$B_TOOL" "$B_SPEC" \
    >"$RESULT_ROOT/evidence/${label}.stdout" 2>"$RESULT_ROOT/evidence/${label}.stderr" &
  bpid=$!
  while kill -0 "$bpid" 2>/dev/null; do
    state=$(ps -o stat= -p "$bpid" 2>/dev/null | tr -d ' ' || true)
    case "$state" in Z*|'') break ;; esac
    current=$(volume_free_bytes)
    [ "$current" -ge "$min_free" ] || min_free=$current
    sleep 0.02
  done
  set +e
  wait "$bpid"
  RUN_B_RC=$?
  set -e
  current=$(volume_free_bytes)
  [ "$current" -ge "$min_free" ] || min_free=$current
  RUN_B_PEAK=$((before - min_free))
  printf 'B_OBSERVATION label=%s pid=%s rc=%s measured_peak_bytes=%s free_before=%s min_free=%s\n' \
    "$label" "$bpid" "$RUN_B_RC" "$RUN_B_PEAK" "$before" "$min_free" \
    >"$RESULT_ROOT/evidence/${label}.capacity.txt"
}

capture_spill() {
  local output=$1 pid=$2
  python3 - "$output" "$pid" "$A_SPILL_FILE" "$A_SPILL_BYTES" <<'PY'
import json, pathlib, sys
out, pid_text, spill_path, minimum = sys.argv[1:]
pid = int(pid_text)
path = pathlib.Path(spill_path)
info = path.stat()
assert info.st_size >= int(minimum)
payload = {
    "pid": pid,
    "path": str(path),
    "dev": info.st_dev,
    "ino": info.st_ino,
    "size": info.st_size,
    "blocks": info.st_blocks,
    "allocated_bytes": info.st_blocks * 512,
}
assert payload["allocated_bytes"] >= int(minimum)
pathlib.Path(out).write_text(json.dumps(payload, indent=2) + "\n")
PY
}

reset_case_paths
b_alone_ok=0
a_healthy=0
b_blocked=0

run_b_monitored b_alone
[ "$RUN_B_RC" -eq 0 ] || fail b_alone_nonzero
b_alone_peak=$RUN_B_PEAK
[ "$b_alone_peak" -ge "$B_PEAK_FLOOR_BYTES" ] || fail b_alone_peak_not_measured
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" \
  >"$RESULT_ROOT/evidence/b_alone_grade.txt" 2>&1 || fail b_alone_artifact_invalid
b_alone_ok=1
rm -rf "$B_DIR"

CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/start_a.sh" \
  >"$RESULT_ROOT/evidence/oracle_start_a.txt"
a_active=1
ready=0
for _ in $(seq 1 160); do
  if CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/status_a.sh" \
    >"$RESULT_ROOT/evidence/oracle_a_ready.txt" 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
[ "$ready" = 1 ] || fail a_never_reached_measured_upload_phase
a_healthy=1
a_pid=$(cat "$A_PID_FILE")
a_starttime=$(awk '{print $22}' "/proc/$a_pid/stat")
capture_spill "$RESULT_ROOT/evidence/spill_before_b.json" "$a_pid" \
  || fail spill_not_attributable
read -r spill_dev spill_ino spill_allocated < <(python3 - "$RESULT_ROOT/evidence/spill_before_b.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(data["dev"], data["ino"], data["allocated_bytes"])
PY
)
[ "$spill_allocated" -ge "$A_SPILL_BYTES" ] || fail spill_below_allocation_floor
visible_bytes=$(du -B1 -sL "$VOLUME_ROOT" | awk '{print $1}')
[ "$visible_bytes" -ge "$A_VISIBLE_FLOOR_BYTES" ] || fail visible_active_working_set_below_floor
free_at_a_peak=$(volume_free_bytes)
parts_before=$(python3 - "$A_PROGRESS" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["parts_uploaded"])
PY
)

run_b_monitored b_with_a
with_a_rc=$RUN_B_RC
[ "$with_a_rc" -ne 0 ] || fail b_unexpectedly_completed_with_a
grep -q 'FEATURE_PUBLISH_FAIL=ENOSPC errno=28' "$RESULT_ROOT/evidence/b_with_a.stderr" \
  || fail b_failure_not_storage_specific
[ ! -e "$B_FINAL" ] || fail b_left_completed_partition_during_conflict
b_blocked=1

progressed=0
for _ in $(seq 1 80); do
  parts_after=$(python3 - "$A_PROGRESS" <<'PY' 2>/dev/null || echo 0
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["parts_uploaded"])
PY
  )
  if [ "$parts_after" -gt "$parts_before" ]; then
    progressed=1
    break
  fi
  sleep 0.05
done
[ "$progressed" = 1 ] || fail a_upload_progress_did_not_advance
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/status_a.sh" \
  >"$RESULT_ROOT/evidence/oracle_a_after_b.txt" 2>&1 || fail a_unhealthy_after_b
[ "$(awk '{print $22}' "/proc/$a_pid/stat")" = "$a_starttime" ] || fail a_identity_changed
capture_spill "$RESULT_ROOT/evidence/spill_after_b.json" "$a_pid" \
  || fail spill_lost_after_b
python3 - "$RESULT_ROOT/evidence/spill_after_b.json" "$spill_dev" "$spill_ino" <<'PY' \
  || fail spill_identity_changed
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert data["dev"] == int(sys.argv[2])
assert data["ino"] == int(sys.argv[3])
PY

CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" normal \
  >"$RESULT_ROOT/evidence/oracle_normal_a_completion.txt"
a_active=0
[ ! -e "$A_SPILL_FILE" ] || fail spill_not_released_after_normal_completion
python3 - "$A_FINAL" "$A_FINAL_MANIFEST" <<'PY' \
  >"$RESULT_ROOT/evidence/oracle_a_result.txt"
import hashlib, json, pathlib, sys
path, manifest = sys.argv[1:]
p = pathlib.Path(path)
data = json.loads(pathlib.Path(manifest).read_text())
assert p.stat().st_size == 4 * 1024 * 1024
with p.open("rb") as handle:
    assert handle.read(6) == b"CKPTQ4"
    handle.seek(-8, 2)
    assert handle.read() == b"CKPTEND4"
digest = hashlib.sha256(p.read_bytes()).hexdigest()
assert data == {"format": "checkpoint-q4-v1", "bytes": 4 * 1024 * 1024, "sha256": digest, "source_shards": 2}
print(f"A_RESULT_OK=1 bytes={p.stat().st_size} sha256={digest}")
PY
[ ! -d "$A_SOURCE_DIR" ] && [ ! -e "$A_QUANT_FILE" ] \
  || fail a_normal_cleanup_left_visible_peak_files
free_after_a=$(volume_free_bytes)
[ $((free_after_a - free_at_a_peak)) -ge 33554432 ] || fail headroom_did_not_recover

rm -rf "$B_DIR"
run_b_monitored b_after_a
[ "$RUN_B_RC" -eq 0 ] || fail b_failed_after_normal_a_cleanup
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" \
  >"$RESULT_ROOT/evidence/b_after_a_grade.txt" 2>&1 || fail b_after_a_artifact_invalid
b_recovery_peak=$RUN_B_PEAK

python3 - "$RESULT_ROOT/evidence/oracle_metrics.json" "$a_pid" "$a_starttime" \
  "$spill_dev" "$spill_ino" "$spill_allocated" "$visible_bytes" "$b_alone_peak" "$with_a_rc" \
  "$parts_before" "$parts_after" "$free_at_a_peak" "$free_after_a" "$b_recovery_peak" <<'PY'
import json, pathlib, sys
keys = ["a_pid", "a_starttime", "spill_dev", "spill_ino", "spill_allocated",
        "visible_bytes", "b_alone_peak", "b_with_a_rc", "parts_before", "parts_after",
        "free_at_a_peak", "free_after_a", "b_recovery_peak"]
values = [int(value) for value in sys.argv[2:]]
pathlib.Path(sys.argv[1]).write_text(json.dumps(dict(zip(keys, values)), indent=2) + "\n")
PY

printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 A_PROGRESS_OK=1 A_RESULT_OK=1 B_RECOVERY_OK=1 RESOURCE=disk_space REASON=active_multipart_spill_peak_enospc SPILL_DEV=%s SPILL_INO=%s ALLOCATED_BYTES=%s B_ALONE_PEAK_BYTES=%s\n' \
  "$spill_dev" "$spill_ino" "$spill_allocated" "$b_alone_peak"

