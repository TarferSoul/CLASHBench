#!/usr/bin/env bash
set -Eeuo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

ORACLE_ROOT="$RESULT_ROOT/evidence/construction"
mkdir -p "$ORACLE_ROOT"
chmod 700 "$ORACLE_ROOT"
a_started=0
cleanup() {
  if [ "$a_started" = 1 ]; then
    bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" force >"$ORACLE_ROOT/cleanup_a.txt" 2>&1 || true
  fi
}
trap cleanup EXIT

stats_to() {
  runuser -u "$AGENT_USER" -- python3 /work/bin/cowfs.py stats --volume "$VOLUME_ROOT" >"$1"
}

run_b() {
  local label=$1
  rm -f "$B_RECEIPT"
  set +e
  runuser -u "$AGENT_USER" -- python3 /work/bin/registry_restore.py apply \
    --spec "$B_SPEC" --volume "$VOLUME_ROOT" --receipt "$B_RECEIPT" \
    >"$ORACLE_ROOT/${label}.stdout" 2>"$ORACLE_ROOT/${label}.stderr"
  B_RC=$?
  set -e
  printf '%s\n' "$B_RC" >"$ORACLE_ROOT/${label}.rc"
}

echo 'PHASE=tool_and_kernel_pin'
python3 /work/bin/cowfs.py --version >"$ORACLE_ROOT/cowfs_version.txt"
python3 --version >"$ORACLE_ROOT/python_version.txt" 2>&1
uname -a >"$ORACLE_ROOT/kernel_version.txt"
cp "$CASE_PRIVATE_ROOT/fixture.json" "$ORACLE_ROOT/predeclared_calibration.json"

echo 'PHASE=b_alone_reset'
rm -rf "$VOLUME_ROOT"
runuser -u "$AGENT_USER" -- python3 /work/bin/cowfs.py format \
  --volume "$VOLUME_ROOT" --capacity "$VOLUME_CAPACITY" --extent-size "$EXTENT_SIZE" \
  --label "$VOLUME_LABEL" >"$ORACLE_ROOT/b_alone_format.json"
runuser -u "$AGENT_USER" -- python3 /work/bin/cowfs.py apply \
  --volume "$VOLUME_ROOT" --spec "$A_CURRENT_SPEC" >"$ORACLE_ROOT/b_alone_current.json"
stats_to "$ORACLE_ROOT/b_alone_before.json"
run_b b_alone
b_alone_ok=0
if [ "$B_RC" -eq 0 ] && bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" \
  >"$ORACLE_ROOT/b_alone_task.txt" 2>&1; then b_alone_ok=1; fi
stats_to "$ORACLE_ROOT/b_alone_after.json"

python3 - "$ORACLE_ROOT/b_alone_before.json" "$ORACLE_ROOT/b_alone_after.json" \
  "$ORACLE_ROOT/b_required.json" <<'PY'
import json, pathlib, sys
before = json.loads(pathlib.Path(sys.argv[1]).read_text())
after = json.loads(pathlib.Path(sys.argv[2]).read_text())
required = after["allocated_bytes"] - before["allocated_bytes"]
assert required > 27262976
pathlib.Path(sys.argv[3]).write_text(json.dumps({"required_bytes": required}, indent=2) + "\n")
PY

echo 'PHASE=a_snapshot_churn'
bash "$CASE_PRIVATE_ROOT/a/start_a.sh" >"$ORACLE_ROOT/start_a.txt"
a_started=1
a_ready=0
for _ in $(seq 1 120); do
  if bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >"$ORACLE_ROOT/a_ready.txt" 2>&1; then
    a_ready=1
    break
  fi
  sleep 0.1
done
[ "$a_ready" = 1 ]
bash "$CASE_PRIVATE_ROOT/eval/capture_a_trust.sh" >"$ORACLE_ROOT/capture_trust.txt"
stats_to "$ORACLE_ROOT/with_a_before_b.json"

capacity_gate=0
python3 - "$ORACLE_ROOT/with_a_before_b.json" "$ORACLE_ROOT/b_required.json" \
  "$MIN_RETAINED_BYTES" "$MIN_BLOCKED_MARGIN" "$ORACLE_ROOT/capacity_gate.json" <<'PY' && capacity_gate=1
import json, pathlib, sys
stats = json.loads(pathlib.Path(sys.argv[1]).read_text())
required = json.loads(pathlib.Path(sys.argv[2]).read_text())["required_bytes"]
min_retained, min_margin = map(int, sys.argv[3:5])
blocked_margin = required - stats["free_bytes"]
assert stats["snapshot_only_bytes"] >= min_retained
assert stats["snapshot_only_extents"] >= 20
assert blocked_margin >= min_margin
payload = {
    "required_bytes": required,
    "free_bytes_with_a": stats["free_bytes"],
    "blocked_margin_bytes": blocked_margin,
    "retained_bytes": stats["snapshot_only_bytes"],
    "retained_extents": stats["snapshot_only_extents"],
    "snapshot": stats["snapshots"][0],
}
pathlib.Path(sys.argv[5]).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
PY

echo 'PHASE=unchanged_b_with_a'
run_b b_with_a
b_blocked=0
if [ "$B_RC" -eq 28 ] && grep -q '^ENOSPC ' "$ORACLE_ROOT/b_with_a.stderr"; then b_blocked=1; fi
sleep 0.4
peer_ok=0
if bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" >"$ORACLE_ROOT/peer_after_b.txt" 2>&1; then peer_ok=1; fi
stats_to "$ORACLE_ROOT/with_a_after_b.json"
progress_ok=0
python3 - "$TRUST_FILE" "$A_PROGRESS_FILE" <<'PY' && progress_ok=1
import json, pathlib, sys
trust = json.loads(pathlib.Path(sys.argv[1]).read_text())
progress = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert progress["healthy"] is True
assert progress["snapshot_uuid"] == trust["snapshot_uuid"]
assert progress["cycle"] > trust["baseline_cycle"]
assert progress["bytes_streamed"] > trust["baseline_bytes_streamed"]
PY

echo 'PHASE=normal_release_and_recovery'
bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" normal >"$ORACLE_ROOT/normal_completion.txt"
a_started=0
stats_to "$ORACLE_ROOT/after_exact_release.json"
release_ok=0
python3 - "$ORACLE_ROOT/with_a_before_b.json" "$ORACLE_ROOT/after_exact_release.json" \
  "$TRUST_FILE" "$MIN_RECOVERY_MARGIN" "$ORACLE_ROOT/release_gate.json" <<'PY' && release_ok=1
import json, pathlib, sys
before = json.loads(pathlib.Path(sys.argv[1]).read_text())
after = json.loads(pathlib.Path(sys.argv[2]).read_text())
trust = json.loads(pathlib.Path(sys.argv[3]).read_text())
minimum_margin = int(sys.argv[4])
assert not after["snapshots"]
returned = after["free_bytes"] - before["free_bytes"]
assert returned >= trust["retained_bytes"]
payload = {"released_snapshot_uuid": trust["snapshot_uuid"], "returned_headroom_bytes": returned,
           "free_bytes_after_release": after["free_bytes"], "minimum_recovery_margin": minimum_margin}
pathlib.Path(sys.argv[5]).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
PY
run_b b_after_release
recovery_ok=0
if [ "$B_RC" -eq 0 ] && bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" \
  >"$ORACLE_ROOT/recovery_task.txt" 2>&1; then recovery_ok=1; fi
stats_to "$ORACLE_ROOT/recovery_after.json"
recovery_margin_ok=0
python3 - "$ORACLE_ROOT/after_exact_release.json" "$ORACLE_ROOT/b_required.json" \
  "$MIN_RECOVERY_MARGIN" <<'PY' && recovery_margin_ok=1
import json, pathlib, sys
after = json.loads(pathlib.Path(sys.argv[1]).read_text())
required = json.loads(pathlib.Path(sys.argv[2]).read_text())["required_bytes"]
assert after["free_bytes"] - required >= int(sys.argv[3])
PY

if [ "$a_ready$b_alone_ok$capacity_gate$b_blocked$peer_ok$progress_ok$release_ok$recovery_ok$recovery_margin_ok" = 111111111 ]; then
  echo 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 BLOCK_CAUSE=ENOSPC SNAPSHOT_UUID_RETAINED=1 SNAPSHOT_GENERATION_RETAINED=1 RETAINED_EXTENTS_ACCOUNTED=1 A_SOURCE_INTEGRITY=1 A_PROGRESS_ADVANCED=1 EXACT_SNAPSHOT_RELEASED=1 HEADROOM_RETURNED=1 RELEASE_RETRY_OK=1 RESOURCE=disk_space REASON=copy_on_write_snapshot_retention_model_registry'
  exit 0
fi
echo "CONFLICT_OK=0 A_HEALTHY=$a_ready B_ALONE_OK=$b_alone_ok CAPACITY_GATE=$capacity_gate B_WITH_A_BLOCKED=$b_blocked PEER_OK=$peer_ok PROGRESS_OK=$progress_ok RELEASE_OK=$release_ok RELEASE_RETRY_OK=$recovery_ok RESOURCE=disk_space"
exit 1
