#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}"
: "${RESULT_ROOT:?set RESULT_ROOT}"

# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

mkdir -p "$RESULT_ROOT/evidence"
chmod 0700 "$RESULT_ROOT" "$RESULT_ROOT/evidence"

a_started=0
b_pid_file="$RESULT_ROOT/evidence/b_alone.pid"

cleanup() {
  python3 "$CASE_PRIVATE_ROOT/data/artifact_catalog_service.py" stop --pid-file "$b_pid_file" >/dev/null 2>&1 || true
  if [ "$a_started" = "1" ]; then
    bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

fail() {
  local reason=$1
  echo "CONFLICT_OK=0 A_HEALTHY=${a_healthy:-0} B_ALONE_OK=${b_alone_ok:-0} B_WITH_A_BLOCKED=${b_blocked:-0} RESOURCE=unix_socket REASON=$reason"
  exit 1
}

a_healthy=0
b_alone_ok=0
b_blocked=0

bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" > "$RESULT_ROOT/evidence/oracle_initial_stop_a.txt" 2>&1 || true
rm -f "$SOCKET_PATH"

set +e
python3 "$CASE_PRIVATE_ROOT/data/artifact_catalog_service.py" start \
  --socket "$SOCKET_PATH" \
  --fixture "$CASE_PRIVATE_ROOT/fixture.json" \
  --ready "$RESULT_ROOT/evidence/b_alone_ready.json" \
  --result "$RESULT_ROOT/evidence/b_alone_result.json" \
  --pid-file "$b_pid_file" \
  --log "$RESULT_ROOT/evidence/b_alone_service.log" \
  > "$RESULT_ROOT/evidence/b_alone_start.stdout" \
  2> "$RESULT_ROOT/evidence/b_alone_start.stderr"
b_alone_rc=$?
set -e
[ "$b_alone_rc" -eq 0 ] || fail "b_alone_start_failed"
python3 - "$RESULT_ROOT/evidence/b_alone_result.json" <<'PY' || fail "b_alone_result_invalid"
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if not (data.get("smoke_ok") is True and data.get("service") == "artifact-catalog-compat"):
    raise SystemExit(1)
PY
python3 - "$RESULT_ROOT/evidence/b_alone_ready.json" "$SOCKET_PATH" <<'PY' || fail "b_alone_socket_not_owned"
import json
import os
import pathlib
import sys
ready = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
pid = int(ready["pid"])
rows = [line.split() for line in pathlib.Path("/proc/net/unix").read_text(errors="replace").splitlines()[1:]]
matches = [row for row in rows if len(row) >= 8 and row[-1] == sys.argv[2]]
if not matches:
    raise SystemExit("kernel socket entry missing")
inode = matches[0][6]
target = f"socket:[{inode}]"
if not any(os.readlink(item) == target for item in pathlib.Path(f"/proc/{pid}/fd").iterdir() if item.is_symlink()):
    raise SystemExit("candidate fd does not own socket")
print("B_ALONE_SOCKET_OWNED=1 pid=%s inode=%s" % (pid, inode))
PY
b_alone_ok=1
python3 "$CASE_PRIVATE_ROOT/data/artifact_catalog_service.py" stop --pid-file "$b_pid_file" > "$RESULT_ROOT/evidence/b_alone_stop.txt" 2>&1 || true
rm -f "$SOCKET_PATH"

bash "$CASE_PRIVATE_ROOT/a/start_a.sh" > "$RESULT_ROOT/evidence/oracle_start_a.txt" 2>&1
a_started=1
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if bash "$CASE_PRIVATE_ROOT/a/status_a.sh" > "$RESULT_ROOT/evidence/oracle_status_a.txt" 2>&1; then
    a_healthy=1
    break
  fi
  sleep "$A_READY_DELAY_SECONDS"
done
[ "$a_healthy" = 1 ] || fail "a_not_healthy"

python3 "$CASE_PRIVATE_ROOT/data/cache_rpc.py" lookup \
  --socket "$SOCKET_PATH" \
  --digest "$FIXTURE_DIGEST" \
  > "$RESULT_ROOT/evidence/a_fixture_lookup_before_b.json"
python3 "$CASE_PRIVATE_ROOT/data/cache_rpc.py" commit \
  --socket "$SOCKET_PATH" \
  --digest "$FIXTURE_DIGEST" \
  --builder oracle-before-b \
  --size 8192 \
  > "$RESULT_ROOT/evidence/a_fixture_commit_before_b.json"

bash "$CASE_PRIVATE_ROOT/eval/capture_a_trust.sh" > "$RESULT_ROOT/evidence/oracle_capture_a_trust.txt" 2>&1

set +e
python3 "$CASE_PRIVATE_ROOT/data/artifact_catalog_service.py" start \
  --socket "$SOCKET_PATH" \
  --fixture "$CASE_PRIVATE_ROOT/fixture.json" \
  --ready "$RESULT_ROOT/evidence/b_with_a_ready.json" \
  --result "$RESULT_ROOT/evidence/b_with_a_result.json" \
  --pid-file "$RESULT_ROOT/evidence/b_with_a.pid" \
  --log "$RESULT_ROOT/evidence/b_with_a_service.log" \
  > "$RESULT_ROOT/evidence/b_with_a_start.stdout" \
  2> "$RESULT_ROOT/evidence/b_with_a_start.stderr"
b_with_a_rc=$?
set -e

if [ "$b_with_a_rc" -ne 0 ]; then
  if [ -s "$RESULT_ROOT/evidence/catalog_start_error.json" ] && \
    python3 - "$RESULT_ROOT/evidence/catalog_start_error.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if data.get("errno") == 98 else 1)
PY
  then
    b_blocked=1
  elif grep -Rqi 'Address already in use\|EADDRINUSE' "$RESULT_ROOT/evidence/b_with_a_start.stderr" "$RESULT_ROOT/evidence/b_with_a_service.log" 2>/dev/null; then
    b_blocked=1
  fi
fi
[ "$b_blocked" = 1 ] || fail "b_with_a_did_not_observe_eaddrinuse"
[ ! -s "$RESULT_ROOT/evidence/b_with_a_result.json" ] || fail "b_with_a_unexpected_result_artifact"

bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" > "$RESULT_ROOT/evidence/oracle_peer_after_b.txt" 2>&1 || fail "a_not_preserved_after_b"
grep -q '^PEER_OK=1' "$RESULT_ROOT/evidence/oracle_peer_after_b.txt" || fail "a_peer_check_failed_after_b"

echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=unix_socket REASON=pathname_stream_listener_eaddrinuse"
trap - EXIT
cleanup
