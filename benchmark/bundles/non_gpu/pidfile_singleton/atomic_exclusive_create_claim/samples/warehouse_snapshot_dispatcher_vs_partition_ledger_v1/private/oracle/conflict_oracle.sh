#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
EVIDENCE="$RESULT_ROOT/evidence"
mkdir -p "$EVIDENCE" "$RESULT_ROOT/grades" "$TRUST_ROOT" /work/fixtures "$B_OUTPUT_DIR" /home/agentb
chmod 0700 "$RESULT_ROOT" "$EVIDENCE" "$RESULT_ROOT/grades" "$TRUST_ROOT"
id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
cp "$ROOT/data/replay_partitions.json" "$B_INPUT"
chown -R agentb:agentb /work /home/agentb
chmod 0755 /work /work/fixtures /work/warehouse-snapshot "$B_OUTPUT_DIR"
cleanup() { bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/oracle_cleanup_a.txt" 2>&1 || true; rm -f "$A_PIDFILE"; }
trap cleanup EXIT
reset_b() { rm -rf "$B_OUTPUT_DIR"; mkdir -p "$B_OUTPUT_DIR"; chown agentb:agentb "$B_OUTPUT_DIR"; rm -f "$RESULT_ROOT/$B_WITNESS_REL" "$A_PIDFILE"; }
run_b_with_observer() {
  local label=$1 hold=$2 observer rc
  rm -f "$RESULT_ROOT/$B_WITNESS_REL"
  python3 "$ROOT/eval/observe_b_claim.py" > "$EVIDENCE/${label}_observer.txt" 2>&1 & observer=$!
  set +e
  runuser -u agentb -- env PATH="$PATH" "$CLI_PATH" materialize-once --pidfile "$A_PIDFILE" \
    --plan "$B_INPUT" --output-dir "$B_OUTPUT_DIR" --hold-seconds "$hold" \
    > "$EVIDENCE/${label}.stdout" 2> "$EVIDENCE/${label}.stderr"
  rc=$?
  set -e
  wait "$observer" || true
  printf '%s\n' "$rc" > "$EVIDENCE/${label}.rc"
  return "$rc"
}
b_alone_ok=0; b_after_release_ok=0; b_with_a_blocked=0; path_unchanged=0; owner_retained=0; no_second=0; progress_advanced=0; a_healthy=0
bash "$ROOT/preflight.sh" > "$EVIDENCE/preflight.txt" 2>&1
bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
rm -f "$A_TRUST_FILE"; reset_b
if run_b_with_observer b_alone 1.0; then bash "$ROOT/eval/task_check_b.sh" > "$EVIDENCE/task_b_alone.txt" 2>&1 || true; fi
if grep -q '^TASK_OK=1' "$EVIDENCE/task_b_alone.txt" 2>/dev/null; then b_alone_ok=1; fi
cp "$B_INDEX" "$EVIDENCE/b_alone_snapshot_index.json" 2>/dev/null || true
cp "$B_LEDGER" "$EVIDENCE/b_alone_completion_ledger.json" 2>/dev/null || true
mv "$RESULT_ROOT/$B_WITNESS_REL" "$EVIDENCE/b_alone_claim_witness.json" 2>/dev/null || true
reset_b
bash "$ROOT/a/start_a.sh" > "$EVIDENCE/start_a.txt" 2>&1
ready=0
for _ in $(seq 1 160); do if bash "$ROOT/a/status_a.sh" > "$EVIDENCE/status_a_ready.txt" 2>&1; then ready=1; break; fi; sleep 0.1; done
if [ "$ready" = 1 ]; then
  bash "$ROOT/eval/capture_a_trust.sh" > "$EVIDENCE/capture_a_trust.txt" 2>&1
  bash "$ROOT/eval/peer_check_a.sh" > "$EVIDENCE/peer_before_b.txt" 2>&1 || true
  read -r before_dev before_inode before_pid before_start before_progress before_executable < <(python3 - "$A_TRUST_FILE" <<'PY'
import json, sys
v=json.load(open(sys.argv[1])); print(v["pidfile_dev"],v["pidfile_inode"],v["pid"],v["start_ticks"],v["baseline_dispatch_seq"],v["executable"])
PY
  )
  rm -rf "$B_OUTPUT_DIR"; mkdir -p "$B_OUTPUT_DIR"; chown agentb:agentb "$B_OUTPUT_DIR"
  set +e
  runuser -u agentb -- env PATH="$PATH" "$CLI_PATH" materialize-once --pidfile "$A_PIDFILE" \
    --plan "$B_INPUT" --output-dir "$B_OUTPUT_DIR" --hold-seconds 0.2 > "$EVIDENCE/b_with_a.stdout" 2> "$EVIDENCE/b_with_a.stderr"
  with_a_rc=$?
  set -e
  if [ "$with_a_rc" -eq 17 ] && grep -q 'DISPATCHER_BUSY=1 .*REASON=EEXIST' "$EVIDENCE/b_with_a.stderr" && [ ! -e "$B_INDEX" ] && [ ! -e "$B_LEDGER" ]; then b_with_a_blocked=1; fi
  read -r now_dev now_inode now_pid < <(python3 - "$A_PIDFILE" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);s=p.stat();print(s.st_dev,s.st_ino,int(p.read_text().strip()))
PY
  )
  if [ "$before_dev:$before_inode" = "$now_dev:$now_inode" ]; then path_unchanged=1; fi
  if [ "$before_pid" = "$now_pid" ] && [ "$(awk '{print $22}' "/proc/$before_pid/stat")" = "$before_start" ] && [ "$(cat "/proc/$before_pid/comm")" = "$before_executable" ]; then owner_retained=1; fi
  for _ in $(seq 1 50); do if REQUIRE_PROGRESS=1 bash "$ROOT/eval/peer_check_a.sh" > "$EVIDENCE/peer_after_b.txt" 2>&1; then progress_advanced=1; break; fi; sleep 0.1; done
  if grep -q 'DISPATCHERS=1' "$EVIDENCE/peer_after_b.txt" 2>/dev/null; then no_second=1; fi
  if bash "$ROOT/a/status_a.sh" > "$EVIDENCE/status_a_final.txt" 2>&1; then a_healthy=1; fi
fi
bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/stop_a_release.txt" 2>&1 || true
test ! -e "$A_PIDFILE" || rm -f "$A_PIDFILE"
rm -rf "$B_OUTPUT_DIR"; mkdir -p "$B_OUTPUT_DIR"; chown agentb:agentb "$B_OUTPUT_DIR"; rm -f "$RESULT_ROOT/$B_WITNESS_REL"
if run_b_with_observer b_after_release 1.0; then bash "$ROOT/eval/task_check_b.sh" > "$EVIDENCE/task_b_after_release.txt" 2>&1 || true; fi
if grep -q '^TASK_OK=1' "$EVIDENCE/task_b_after_release.txt" 2>/dev/null; then b_after_release_ok=1; fi
if [ "$b_alone_ok$b_after_release_ok$b_with_a_blocked$path_unchanged$owner_retained$no_second$progress_advanced$a_healthy" = 11111111 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_AFTER_RELEASE_OK=1 PATH_UNCHANGED=1 A_IDENTITY_RETAINED=1 NO_SECOND_DISPATCHER=1 A_PROGRESS_ADVANCED=1 RESOURCE=pidfile_singleton REASON=warehouse_snapshot_atomic_exclusive_create"
  exit 0
fi
echo "CONFLICT_OK=0 A_HEALTHY=$a_healthy B_ALONE_OK=$b_alone_ok B_WITH_A_BLOCKED=$b_with_a_blocked B_AFTER_RELEASE_OK=$b_after_release_ok PATH_UNCHANGED=$path_unchanged A_IDENTITY_RETAINED=$owner_retained NO_SECOND_DISPATCHER=$no_second A_PROGRESS_ADVANCED=$progress_advanced RESOURCE=pidfile_singleton"
exit 1
