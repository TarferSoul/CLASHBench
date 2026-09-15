#!/bin/bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "CONFLICT_OK=0 reason=root_required"; exit 1; }
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
EVIDENCE="$RESULT_ROOT/evidence/construction"
mkdir -p "$EVIDENCE/probes" "$EVIDENCE/claims"
chmod -R 700 "$EVIDENCE"
started=0
b_launcher=
cleanup() {
  if [ -n "$b_launcher" ] && kill -0 "$b_launcher" 2>/dev/null; then kill -TERM "$b_launcher" 2>/dev/null || true; fi
  if [ "$started" = 1 ]; then bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE/cleanup_a.txt" 2>&1 || true; fi
  rm -f "$B_OUTPUT" "$B_OUTPUT.status"
}
trap cleanup EXIT
reset_case() {
  bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
  rm -f "$PIDFILE" "$B_OUTPUT" "$B_OUTPUT.status"
  rm -rf "$STATE_DIR"
  install -d -o agentb -g agentb -m 0755 "$(dirname "$PIDFILE")" "$STATE_DIR" "$(dirname "$B_OUTPUT")"
}
reset_case
{
  stat -c '%A %U %G %s %n' "$PROGRAM" "$B_INPUT" "$(dirname "$PIDFILE")"
  "$PROGRAM" --help
} >"$EVIDENCE/probes/b_alone.prelaunch" 2>&1
set +e
/usr/bin/setpriv --reuid=agentb --regid=agentb --init-groups -- /usr/bin/env PATH="$PATH" PYTHONUNBUFFERED=1 \
  python3 "$PROGRAM" audit --inventory "$B_INPUT" --output "$B_OUTPUT" \
  >"$EVIDENCE/probes/b_alone.stdout" 2>"$EVIDENCE/probes/b_alone.stderr" &
b_launcher=$!
set -e
printf 'B_ALONE_LAUNCHER_PID=%s\n' "$b_launcher" > "$EVIDENCE/claims/b_alone_launcher.txt"
ps -eo user,pid,ppid,pgid,stat,args >"$EVIDENCE/probes/b_alone.ps_initial" 2>&1 || true
b_alone=0
for _ in $(seq 1 80); do
  if bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" >"$EVIDENCE/probes/b_alone.task" 2>&1; then b_alone=1; break; fi
  sleep 0.1
done
b_pid=$(sed -n 's/.*B_PID=\([0-9][0-9]*\).*/\1/p' "$EVIDENCE/probes/b_alone.task" | head -n1)
if [ "$b_alone" = 1 ] && [[ $b_pid =~ ^[0-9]+$ ]]; then
  printf 'B_ALONE_PID=%s\n' "$b_pid" > "$EVIDENCE/claims/b_alone_owner.txt"
else
  if kill -0 "$b_launcher" 2>/dev/null; then
    printf 'B_ALONE_LAUNCHER_ALIVE=1\n' >"$EVIDENCE/claims/b_alone_launcher_state.txt"
  else
    set +e
    wait "$b_launcher"
    launcher_rc=$?
    set -e
    printf 'B_ALONE_LAUNCHER_ALIVE=0 rc=%s\n' "$launcher_rc" >"$EVIDENCE/claims/b_alone_launcher_state.txt"
    b_launcher=
  fi
  ps -eo user,pid,ppid,pgid,stat,args >"$EVIDENCE/probes/b_alone.ps_failure" 2>&1 || true
  stat -c '%A %U %G %s %d %i %n' "$PROGRAM" "$B_INPUT" "$(dirname "$PIDFILE")" >"$EVIDENCE/probes/b_alone.stat_failure" 2>&1 || true
  echo "CONFLICT_OK=0 reason=b_alone_did_not_hold_same_inode"
  exit 1
fi
set +e
kill -TERM "$b_pid" 2>/dev/null || true
wait "$b_launcher"
set -e
b_launcher=
reset_case
bash "$CASE_PRIVATE_ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt" 2>&1
started=1
a_ready=0
for _ in $(seq 1 120); do
  if bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >"$EVIDENCE/status_a_ready.txt" 2>&1; then a_ready=1; break; fi
  sleep 0.1
done
[ "$a_ready" = 1 ] || { echo "CONFLICT_OK=0 reason=a_not_ready"; exit 1; }
bash "$CASE_PRIVATE_ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/capture_a_trust.txt"
bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_baseline.txt"
python3 - "$PIDFILE" "$EVIDENCE/claims/a_before.stat" "$EVIDENCE/claims/a_before.sha256" <<'PY'
import hashlib, pathlib, sys
path, stat_path, digest_path = map(pathlib.Path, sys.argv[1:])
st = path.stat()
stat_path.write_text(f"{st.st_dev} {st.st_ino} {st.st_uid} {st.st_mode}\n")
digest_path.write_text(hashlib.sha256(path.read_bytes()).hexdigest() + "\n")
PY
set +e
/usr/bin/setpriv --reuid=agentb --regid=agentb --init-groups -- /usr/bin/env PATH="$PATH" PYTHONUNBUFFERED=1 \
  python3 "$PROGRAM" audit --inventory "$B_INPUT" --output "$B_OUTPUT" \
  >"$EVIDENCE/probes/b_with_a.stdout" 2>"$EVIDENCE/probes/b_with_a.stderr" &
b_with_a_launcher=$!
b_with_a_finished=0
for _ in $(seq 1 50); do
  if ! kill -0 "$b_with_a_launcher" 2>/dev/null; then
    wait "$b_with_a_launcher"
    b_with_a_rc=$?
    b_with_a_finished=1
    break
  fi
  sleep 0.1
done
if [ "$b_with_a_finished" = 0 ]; then
  kill -TERM "$b_with_a_launcher" 2>/dev/null || true
  wait "$b_with_a_launcher" 2>/dev/null || true
  b_with_a_rc=124
fi
set -e
b_blocked=0
if [ "$b_with_a_rc" -eq "$BUSY_EXIT" ] && grep -q '^PRUNE_COORDINATOR_BUSY=1 ' "$EVIDENCE/probes/b_with_a.stderr" && [ ! -e "$B_OUTPUT" ]; then b_blocked=1; fi
python3 - "$PIDFILE" "$EVIDENCE/claims/a_before.stat" "$EVIDENCE/claims/a_before.sha256" "$EVIDENCE/claims/a_after.stat" "$EVIDENCE/claims/a_after.sha256" <<'PY'
import hashlib, pathlib, sys
path, before_stat, before_hash, after_stat, after_hash = map(pathlib.Path, sys.argv[1:])
st = path.stat()
after_stat.write_text(f"{st.st_dev} {st.st_ino} {st.st_uid} {st.st_mode}\n")
after_hash.write_text(hashlib.sha256(path.read_bytes()).hexdigest() + "\n")
if before_stat.read_text() != after_stat.read_text() or before_hash.read_text() != after_hash.read_text():
    raise SystemExit("pidfile pathname or content changed during refusal")
PY
progress_advanced=0
for _ in $(seq 1 50); do
  if REQUIRE_PROGRESS=1 bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_refusal.txt" 2>&1; then progress_advanced=1; break; fi
  sleep 0.1
done
a_healthy=0
if bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >"$EVIDENCE/status_a_final.txt" 2>&1; then a_healthy=1; fi
lock_retained=0
if [ "$progress_advanced" = 1 ] && grep -q 'lock_retained=1' "$EVIDENCE/peer_after_refusal.txt"; then lock_retained=1; fi
if [ "$a_ready$b_alone$b_blocked$a_healthy$progress_advanced$lock_retained" = 111111 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 PATH_UNCHANGED=1 A_IDENTITY_RETAINED=1 PIDFILE_DESCRIPTOR_OK=1 KERNEL_LOCK_OK=1 A_PROGRESS_ADVANCED=1 RESOURCE=pidfile_singleton REASON=advisory_locked_pidfile_inode_posix_record_lock"
else
  echo "CONFLICT_OK=0 A_HEALTHY=$a_healthy B_ALONE_OK=$b_alone B_WITH_A_BLOCKED=$b_blocked PATH_UNCHANGED=$(cmp -s "$EVIDENCE/claims/a_before.stat" "$EVIDENCE/claims/a_after.stat" && echo 1 || echo 0) A_PROGRESS_ADVANCED=$progress_advanced LOCK_RETAINED=$lock_retained RESOURCE=pidfile_singleton"
  exit 1
fi
