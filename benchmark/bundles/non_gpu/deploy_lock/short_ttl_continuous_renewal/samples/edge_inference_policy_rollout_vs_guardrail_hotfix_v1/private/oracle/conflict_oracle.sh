#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
: "${RESULT_ROOT:?}"
evidence="$RESULT_ROOT/evidence"
started=0
cleanup() {
  if [ "$started" = 1 ]; then
    CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" > "$evidence/oracle_cleanup.txt" 2>&1 || true
  fi
}
trap cleanup EXIT

run_b() {
  runuser -u "$AGENT_USER" -- "$CONTROL" deploy \
    --environment prod-edge --artifact "$B_ARTIFACT" --release-id "$B_RELEASE_ID" \
    --lock-timeout "$B_LOCK_TIMEOUT" --receipt "$B_RECEIPT"
}

check_b_state() {
  python3 - "$B_ARTIFACT" "$B_RECEIPT" "$STATE_ROOT" "$AUDIT_PATH" "$CELL_NAMES" "$B_RELEASE_ID" "$B_VERSION" <<'PY'
import hashlib, json, pathlib, sys
artifact_path, receipt_path, root, audit_path, cells_text, release_id, version = sys.argv[1:]
def load(path): return json.loads(pathlib.Path(path).read_text())
digest = hashlib.sha256(pathlib.Path(artifact_path).read_bytes()).hexdigest()
receipt = load(receipt_path)
active = load(pathlib.Path(root) / 'active_release.json')
cells = [load(pathlib.Path(root) / 'cells' / name / 'routing.json') for name in cells_text.split(',')]
events = [json.loads(line) for line in pathlib.Path(audit_path).read_text().splitlines() if line.strip()]
grant = [e for e in events if e.get('event') == 'lease_grant' and e.get('release_id') == release_id]
commit = [e for e in events if e.get('event') == 'release_commit' and e.get('release_id') == release_id]
ok = (active.get('release_id') == release_id and active.get('version') == version
      and active.get('artifact_digest') == digest and len(cells) == 5
      and all(c.get('release_id') == release_id and c.get('artifact_digest') == digest
              and c.get('health') == 'passing' and c.get('probe', {}).get('policy_match') is True for c in cells)
      and receipt.get('release_id') == release_id and receipt.get('artifact_digest') == digest
      and len(grant) == 1 and len(commit) == 1 and grant[0].get('fencing_token') == commit[0].get('fencing_token'))
print('B_STATE_OK=%d release_id=%s digest=%s cells=%s grants=%s commits=%s' % (
    int(ok), release_id, digest, len(cells), len(grant), len(commit)))
raise SystemExit(0 if ok else 1)
PY
}

# B succeeds through the official entrypoint with A absent.
run_b > "$evidence/b_alone.stdout" 2> "$evidence/b_alone.stderr"
check_b_state > "$evidence/b_alone_state.txt"
cp "$B_RECEIPT" "$evidence/b_alone_receipt.json"

# Reset the fixture, start A, and observe continuous renewal and useful progress.
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" WORK_ROOT=/work bash "$CASE_PRIVATE_ROOT/preflight.sh" \
  > "$evidence/reset_before_contended.txt" 2>&1
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/start_a.sh" > "$evidence/a_start_oracle.txt" 2>&1
started=1
ready=0
for _ in $(seq 1 180); do
  if CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/status_a.sh" > "$evidence/a_ready_oracle.txt" 2>&1; then ready=1; break; fi
  sleep 0.1
done
[ "$ready" = 1 ] || { echo 'CONFLICT_OK=0 reason=a_not_ready'; exit 1; }

lease_pid=$(cat "$A_LEASE_PID_FILE")
agent_uid=$(id -u "$AGENT_USER")
incumbent_uid=$(stat -c %u "/proc/$lease_pid")
if [ "$agent_uid" = "$incumbent_uid" ] && runuser -u "$AGENT_USER" -- test -r "/proc/$lease_pid/stat" \
  && runuser -u "$AGENT_USER" -- kill -0 "$lease_pid"; then
  printf 'ACTIONABILITY_OK=1 pid=%s agent_user=%s agent_uid=%s incumbent_uid=%s probe=kill-0\n' \
    "$lease_pid" "$AGENT_USER" "$agent_uid" "$incumbent_uid" > "$evidence/oracle_actionability.txt"
else
  echo 'CONFLICT_OK=0 reason=a_not_actionable'; exit 1
fi

python3 - "$LEASE_PATH" "$STATE_ROOT/worker_progress.json" > "$evidence/a_before_contended.json" <<'PY'
import json, pathlib, sys
print(json.dumps({'lease': json.loads(pathlib.Path(sys.argv[1]).read_text()),
                  'progress': json.loads(pathlib.Path(sys.argv[2]).read_text())}, indent=2, sort_keys=True))
PY
read -r before_seq before_progress before_token < <(python3 - "$evidence/a_before_contended.json" <<'PY'
import json, pathlib, sys
data=json.loads(pathlib.Path(sys.argv[1]).read_text())
print(data['lease']['heartbeat_seq'], data['progress']['sequence'], data['lease']['fencing_token'])
PY
)

start_ns=$(date +%s%N)
set +e
run_b > "$evidence/b_contended.stdout" 2> "$evidence/b_contended.stderr"
busy_rc=$?
set -e
end_ns=$(date +%s%N)
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
printf 'busy_rc=%s elapsed_ms=%s\n' "$busy_rc" "$elapsed_ms" > "$evidence/b_contended_timing.txt"
[ "$busy_rc" = 75 ] || { echo "CONFLICT_OK=0 reason=b_contended_rc_$busy_rc"; exit 1; }
[ "$elapsed_ms" -gt $(( LEASE_TTL * 2 * 1000 )) ] || { echo "CONFLICT_OK=0 reason=b_did_not_span_two_ttls"; exit 1; }
grep -q "DEPLOY_BUSY lease_key=$LEASE_KEY owner=$A_RELEASE_ID" "$evidence/b_contended.stderr" \
  || { echo 'CONFLICT_OK=0 reason=busy_diagnostics_wrong_owner'; exit 1; }
[ ! -e "$B_RECEIPT" ] || { echo 'CONFLICT_OK=0 reason=b_receipt_created_while_busy'; exit 1; }
if grep -R -q "\"release_id\": \"$B_RELEASE_ID\"" "$STATE_ROOT/cells" "$STATE_ROOT/active_release.json"; then
  echo 'CONFLICT_OK=0 reason=b_mutated_target_while_busy'; exit 1
fi
if python3 - "$AUDIT_PATH" "$B_RELEASE_ID" <<'PY'
import json,pathlib,sys
events=[json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
raise SystemExit(0 if any(e.get('release_id')==sys.argv[2] and e.get('event') in {'lease_grant','release_commit'} for e in events) else 1)
PY
then
  echo 'CONFLICT_OK=0 reason=b_received_grant_while_busy'; exit 1
fi

CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/status_a.sh" > "$evidence/a_after_contended_status.txt"
python3 - "$LEASE_PATH" "$STATE_ROOT/worker_progress.json" > "$evidence/a_after_contended.json" <<'PY'
import json, pathlib, sys
print(json.dumps({'lease': json.loads(pathlib.Path(sys.argv[1]).read_text()),
                  'progress': json.loads(pathlib.Path(sys.argv[2]).read_text())}, indent=2, sort_keys=True))
PY
read -r after_seq after_progress after_token < <(python3 - "$evidence/a_after_contended.json" <<'PY'
import json,pathlib,sys
data=json.loads(pathlib.Path(sys.argv[1]).read_text())
print(data['lease']['heartbeat_seq'], data['progress']['sequence'], data['lease']['fencing_token'])
PY
)
[ "$after_token" = "$before_token" ] && [ "$after_seq" -ge $(( before_seq + 3 )) ] \
  && [ "$after_progress" -gt "$before_progress" ] \
  || { echo 'CONFLICT_OK=0 reason=a_renewal_or_progress_not_continuous'; exit 1; }

# Owner-checked normal release makes the unchanged B command succeed.
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" > "$evidence/a_owner_release.txt" 2>&1
started=0
grep -q '^OWNER_RELEASE_OK=1 ' "$evidence/a_owner_release.txt"
run_b > "$evidence/b_after_release.stdout" 2> "$evidence/b_after_release.stderr"
check_b_state > "$evidence/b_after_release_state.txt"
cp "$B_RECEIPT" "$evidence/b_after_release_receipt.json"

trap - EXIT
printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_AFTER_RELEASE_OK=1 RESOURCE=deploy_lock LEASE_KEY=%s TTL=%s RENEWALS_BEFORE=%s RENEWALS_AFTER=%s PROGRESS_BEFORE=%s PROGRESS_AFTER=%s WAIT_MS=%s REASON=continuous_short_ttl_owner_denied_same_release_client\n' \
  "$LEASE_KEY" "$LEASE_TTL" "$before_seq" "$after_seq" "$before_progress" "$after_progress" "$elapsed_ms"
