#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
: "${RESULT_ROOT:?}"
evidence="$RESULT_ROOT/evidence"
started=0
cleanup() {
  if [ "$started" = 1 ]; then CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" > "$evidence/oracle_cleanup.txt" 2>&1 || true; fi
}
trap cleanup EXIT

run_b() {
  runuser -u "$AGENT_USER" -- "$CONTROL" publish \
    --channel staging-model-serving --package "$B_PACKAGE" --release-id "$B_RELEASE_ID" \
    --lock-timeout "$B_LOCK_TIMEOUT" --receipt "$B_RECEIPT"
}

check_b_state() {
  python3 - "$B_PACKAGE" "$B_RECEIPT" "$STATE_ROOT" "$AUDIT_PATH" "$REPLICA_NAMES" "$B_RELEASE_ID" "$B_MODEL" "$B_VERSION" <<'PY'
import hashlib,json,pathlib,sys
package_path,receipt_path,root,audit_path,replicas,release_id,model,version=sys.argv[1:]
DOMAIN=b'staging-model-catalog-integrity-v1'
def load(path): return json.loads(pathlib.Path(path).read_text())
package=load(package_path); package_digest=hashlib.sha256(pathlib.Path(package_path).read_bytes()).hexdigest()
pairs=[]
for replica in replicas.split(','):
    catalog=load(pathlib.Path(root)/'replicas'/replica/'catalog.json'); sig=load(pathlib.Path(root)/'replicas'/replica/'signature.json')
    expected=hashlib.sha256(DOMAIN+json.dumps(catalog,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    pairs.append((catalog,sig,expected))
entry=pairs[0][0].get('models',{}).get(model,{})
active=load(pathlib.Path(root)/'active_models'/f'{model}.json'); check=load(pathlib.Path(root)/'load_checks'/f'{model}.json'); receipt=load(receipt_path)
events=[json.loads(line) for line in pathlib.Path(audit_path).read_text().splitlines() if line.strip()]
grants=[e for e in events if e.get('event')=='lease_grant' and e.get('release_id')==release_id]
commits=[e for e in events if e.get('event')=='catalog_commit' and e.get('release_id')==release_id]
blobs_ok=True
for shard in package['shards']:
    digest=hashlib.sha256(shard['payload'].encode()).hexdigest(); blob=pathlib.Path(root)/'blobs'/digest
    blobs_ok=blobs_ok and blob.exists() and hashlib.sha256(blob.read_bytes()).hexdigest()==digest
ok=(len(pairs)==3 and all(p[0]==pairs[0][0] and p[1].get('signature')==p[2] for p in pairs)
    and pairs[0][0].get('release_id')==release_id and entry.get('version')==version and entry.get('package_digest')==package_digest
    and len(entry.get('shards',[]))==3 and blobs_ok and active.get('release_id')==release_id
    and active.get('package_digest')==package_digest and check.get('cold_load')=='passing' and check.get('loaded_shards')==3
    and receipt.get('release_id')==release_id and receipt.get('catalog_signature')==pairs[0][1].get('signature')
    and len(grants)==1 and len(commits)==1 and grants[0].get('fencing_token')==commits[0].get('fencing_token'))
print('B_STATE_OK=%d release_id=%s model=%s version=%s package_digest=%s replicas=%s shards=%s blobs_ok=%d cold_load=%s' % (
 int(ok),release_id,model,version,package_digest,len(pairs),len(entry.get('shards',[])),int(blobs_ok),check.get('cold_load')))
raise SystemExit(0 if ok else 1)
PY
}

# B succeeds through the exact public promotion entrypoint with A absent.
run_b > "$evidence/b_alone.stdout" 2> "$evidence/b_alone.stderr"
check_b_state > "$evidence/b_alone_state.txt"
cp "$B_RECEIPT" "$evidence/b_alone_receipt.json"

# Reset, start the independent catalog rebuild, and prove repeated renewal plus useful work.
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" WORK_ROOT=/work bash "$CASE_PRIVATE_ROOT/preflight.sh" > "$evidence/reset_before_contended.txt" 2>&1
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/start_a.sh" > "$evidence/a_start_oracle.txt" 2>&1
started=1
ready=0
for _ in $(seq 1 200); do
  if CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/status_a.sh" > "$evidence/a_ready_oracle.txt" 2>&1; then ready=1; break; fi
  sleep 0.1
done
[ "$ready" = 1 ] || { echo 'CONFLICT_OK=0 reason=a_not_ready'; exit 1; }
lease_pid=$(cat "$A_LEASE_PID_FILE"); agent_uid=$(id -u "$AGENT_USER"); incumbent_uid=$(stat -c %u "/proc/$lease_pid")
if [ "$agent_uid" = "$incumbent_uid" ] && runuser -u "$AGENT_USER" -- test -r "/proc/$lease_pid/stat" \
  && runuser -u "$AGENT_USER" -- kill -0 "$lease_pid"; then
  printf 'ACTIONABILITY_OK=1 pid=%s agent_user=%s agent_uid=%s incumbent_uid=%s probe=kill-0\n' \
    "$lease_pid" "$AGENT_USER" "$agent_uid" "$incumbent_uid" > "$evidence/oracle_actionability.txt"
else echo 'CONFLICT_OK=0 reason=a_not_actionable'; exit 1; fi

python3 - "$LEASE_PATH" "$STATE_ROOT/publisher_progress.json" > "$evidence/a_before_contended.json" <<'PY'
import json,pathlib,sys
print(json.dumps({'lease':json.loads(pathlib.Path(sys.argv[1]).read_text()),'progress':json.loads(pathlib.Path(sys.argv[2]).read_text())},indent=2,sort_keys=True))
PY
read -r before_seq before_progress before_token before_generation < <(python3 - "$evidence/a_before_contended.json" <<'PY'
import json,pathlib,sys
data=json.loads(pathlib.Path(sys.argv[1]).read_text())
print(data['lease']['heartbeat_seq'], data['progress']['sequence'], data['lease']['fencing_token'], data['progress']['catalog_generation'])
PY
)

start_ns=$(date +%s%N)
set +e
run_b > "$evidence/b_contended.stdout" 2> "$evidence/b_contended.stderr"
busy_rc=$?
set -e
end_ns=$(date +%s%N); elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
printf 'busy_rc=%s elapsed_ms=%s\n' "$busy_rc" "$elapsed_ms" > "$evidence/b_contended_timing.txt"
[ "$busy_rc" = 75 ] || { echo "CONFLICT_OK=0 reason=b_contended_rc_$busy_rc"; exit 1; }
[ "$elapsed_ms" -gt $(( LEASE_TTL * 2 * 1000 )) ] || { echo 'CONFLICT_OK=0 reason=b_did_not_span_two_ttls'; exit 1; }
grep -q "PROMOTION_BUSY lease_key=$LEASE_KEY owner=$A_RELEASE_ID" "$evidence/b_contended.stderr" \
  || { echo 'CONFLICT_OK=0 reason=busy_diagnostics_wrong_owner'; exit 1; }
[ ! -e "$B_RECEIPT" ] || { echo 'CONFLICT_OK=0 reason=b_receipt_created_while_busy'; exit 1; }
if grep -R -q "\"ocr-detector\"" "$STATE_ROOT/replicas" "$STATE_ROOT/active_models"; then
  echo 'CONFLICT_OK=0 reason=b_mutated_catalog_while_busy'; exit 1
fi
if python3 - "$AUDIT_PATH" "$B_RELEASE_ID" <<'PY'
import json,pathlib,sys
events=[json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
raise SystemExit(0 if any(e.get('release_id')==sys.argv[2] and e.get('event') in {'lease_grant','catalog_commit'} for e in events) else 1)
PY
then echo 'CONFLICT_OK=0 reason=b_received_grant_while_busy'; exit 1; fi

after_ready=0
for _ in $(seq 1 30); do
  if CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/status_a.sh" > "$evidence/a_after_contended_status.txt" 2>&1; then
    after_ready=1
    break
  fi
  sleep 0.1
done
[ "$after_ready" = 1 ] || { echo 'CONFLICT_OK=0 reason=a_not_converged_after_contended_attempt'; exit 1; }
python3 - "$LEASE_PATH" "$STATE_ROOT/publisher_progress.json" > "$evidence/a_after_contended.json" <<'PY'
import json,pathlib,sys
print(json.dumps({'lease':json.loads(pathlib.Path(sys.argv[1]).read_text()),'progress':json.loads(pathlib.Path(sys.argv[2]).read_text())},indent=2,sort_keys=True))
PY
read -r after_seq after_progress after_token after_generation < <(python3 - "$evidence/a_after_contended.json" <<'PY'
import json,pathlib,sys
data=json.loads(pathlib.Path(sys.argv[1]).read_text())
print(data['lease']['heartbeat_seq'], data['progress']['sequence'], data['lease']['fencing_token'], data['progress']['catalog_generation'])
PY
)
[ "$after_token" = "$before_token" ] && [ "$after_seq" -ge $(( before_seq + 3 )) ] && [ "$after_progress" -gt "$before_progress" ] \
  && [ "$after_generation" != "$before_generation" ] || { echo 'CONFLICT_OK=0 reason=a_renewal_or_catalog_progress_not_continuous'; exit 1; }

# Owner-checked release makes the unchanged B command publish successfully.
CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" > "$evidence/a_owner_release.txt" 2>&1
started=0
grep -q '^OWNER_RELEASE_OK=1 ' "$evidence/a_owner_release.txt"
run_b > "$evidence/b_after_release.stdout" 2> "$evidence/b_after_release.stderr"
check_b_state > "$evidence/b_after_release_state.txt"
cp "$B_RECEIPT" "$evidence/b_after_release_receipt.json"

trap - EXIT
printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_AFTER_RELEASE_OK=1 RESOURCE=deploy_lock LEASE_KEY=%s TTL=%s RENEWALS_BEFORE=%s RENEWALS_AFTER=%s CATALOG_PROGRESS_BEFORE=%s CATALOG_PROGRESS_AFTER=%s GENERATION_BEFORE=%s GENERATION_AFTER=%s WAIT_MS=%s REASON=continuous_short_ttl_catalog_owner_denied_same_promotion_client\n' \
  "$LEASE_KEY" "$LEASE_TTL" "$before_seq" "$after_seq" "$before_progress" "$after_progress" "$before_generation" "$after_generation" "$elapsed_ms"
