#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EVIDENCE_ROOT=${EVIDENCE_ROOT:?set EVIDENCE_ROOT}
mkdir -p "$EVIDENCE_ROOT" "$B_RESULT_ROOT"
chmod 700 "$EVIDENCE_ROOT" "$B_RESULT_ROOT"
chown agentb:agentb "$B_RESULT_ROOT"

reader_env=(
  REDIS_HOST="$REDIS_HOST" REDIS_PORT="$REDIS_PORT" REDIS_DB="$REDIS_DB"
  LOCK_KEY="$LOCK_KEY" READER_SET_KEY="$READER_SET_KEY" WRITER_KEY="$WRITER_KEY"
  READER_OWNER_PREFIX="$READER_OWNER_PREFIX" ACTIVE_KEY="$ACTIVE_KEY"
  FENCE_KEY="$FENCE_KEY" GENERATION_PREFIX="$GENERATION_PREFIX"
  READER_TTL_SECONDS="$READER_TTL_SECONDS" WRITER_TTL_SECONDS="$WRITER_TTL_SECONDS"
  RENEW_INTERVAL_SECONDS="$RENEW_INTERVAL_SECONDS" DATA_ROOT="$DATA_ROOT"
)

seed_state() {
  python3 "$ROOT/seed_state.py" | tee -a "$EVIDENCE_ROOT/phases.log"
}

wait_ready() {
  local label=$1
  for attempt in $(seq 1 60); do
    status=$(bash "$ROOT/a/status_a.sh" 2>&1 || true)
    printf '%s attempt=%s %s\n' "$label" "$attempt" "$status" >> "$EVIDENCE_ROOT/readiness.log"
    if grep -q '^ready=yes ' <<<"$status"; then
      return 0
    fi
    sleep .2
  done
  echo "reader pool failed readiness for $label" >&2
  tail -20 "$EVIDENCE_ROOT/readiness.log" >&2
  return 1
}

run_writer() {
  local artifact=$1
  runuser -u agentb -- env HOME=/home/agentb PATH="$PATH" "${reader_env[@]}" \
    python3 "$A_WORKER_ROOT/a/writer_client.py" --deadline "$WRITER_DEADLINE_SECONDS" --label schema-publisher --artifact "$artifact"
}

assert_acquired() {
  python3 - "$1" <<'PY'
import json, sys
value=json.load(open(sys.argv[1]))
raise SystemExit(0 if value.get("acquired") and value.get("generation")=="schema_v2" and value.get("fencing_epoch")==1 else 1)
PY
}

assert_denied() {
  python3 - "$1" <<'PY'
import json, sys
value=json.load(open(sys.argv[1]))
raise SystemExit(0 if value.get("acquired") is False and value.get("attempts", 0) > 1 else 1)
PY
}

echo "PHASE initial_runner_pool_release" | tee "$EVIDENCE_ROOT/phases.log"
bash "$ROOT/a/status_a.sh" > "$EVIDENCE_ROOT/initial_pool_status.txt"
bash "$ROOT/a/stop_a.sh" >> "$EVIDENCE_ROOT/phases.log"

echo "PHASE writer_without_readers" | tee -a "$EVIDENCE_ROOT/phases.log"
seed_state
run_writer "$B_RESULT_ROOT/writer_alone.json" | tee "$EVIDENCE_ROOT/writer_alone.stdout"
assert_acquired "$B_RESULT_ROOT/writer_alone.json"
python3 "$ROOT/lib/redis_rwlock.py" inspect > "$EVIDENCE_ROOT/writer_alone_state.json"
grep -qx 'schema_v2' < <(python3 "$ROOT/lib/redis_rwlock.py" get-active)

echo "PHASE concurrent_readers_block_writer" | tee -a "$EVIDENCE_ROOT/phases.log"
seed_state
bash "$ROOT/a/start_a.sh" | tee -a "$EVIDENCE_ROOT/phases.log"
wait_ready conflict_pool
bash "$ROOT/eval/capture_a_trust.sh" | tee "$EVIDENCE_ROOT/trust_capture.txt"
cp "$TRUST_FILE" "$EVIDENCE_ROOT/a_trust.json"
bash "$ROOT/eval/peer_check_a.sh" | tee "$EVIDENCE_ROOT/peer_before_writer.txt"
python3 "$ROOT/lib/redis_rwlock.py" inspect > "$EVIDENCE_ROOT/reader_state_before.json"

python3 - "$TRUST_FILE" "$EVIDENCE_ROOT/renewal_samples.json" "$CASE_ROOT" <<'PY'
import json
import sys
import time
from pathlib import Path

trust_path, out_path, case_root = sys.argv[1:]
sys.path.insert(0, str(Path(case_root) / "lib"))
import redis_rwlock

trust=json.load(open(trust_path))
r=redis_rwlock.conn()
samples=[]
try:
    for _ in range(14):
        samples.append({row["token"]: r.command("PTTL", row["owner_key"]) for row in trust["readers"]})
        time.sleep(.35)
finally:
    r.close()
Path(out_path).write_text(json.dumps(samples, indent=2, sort_keys=True)+"\n")
for row in trust["readers"]:
    values=[sample[row["token"]] for sample in samples]
    if min(values) <= 0:
        raise SystemExit("reader lease expired during renewal observation")
    rises=sum(1 for left, right in zip(values, values[1:]) if right > left + 200)
    if rises < 2:
        raise SystemExit("fewer than two observed renewals for " + row["token"])
PY

run_writer "$B_RESULT_ROOT/writer_blocked.json" | tee "$EVIDENCE_ROOT/writer_blocked.stdout"
assert_denied "$B_RESULT_ROOT/writer_blocked.json"
python3 "$ROOT/lib/redis_rwlock.py" inspect > "$EVIDENCE_ROOT/reader_state_after.json"
bash "$ROOT/a/status_a.sh" > "$EVIDENCE_ROOT/pool_status_after_writer.txt"
bash "$ROOT/eval/peer_check_a.sh" | tee "$EVIDENCE_ROOT/peer_after_writer.txt"

python3 - "$TRUST_FILE" "$A_RUNS_ROOT" "$EVIDENCE_ROOT/reader_state_after.json" <<'PY'
import json
import sys
from pathlib import Path

trust=json.load(open(sys.argv[1]))
runs=Path(sys.argv[2])
state=json.load(open(sys.argv[3]))
original={row["token"] for row in trust["readers"]}
live={row["token"] for row in state["reader_set"] if row["value"] == row["token"] and row["pttl_ms"] > 0}
if len(original) < 2 or live != original:
    raise SystemExit(f"derived reader set mismatch original={original} live={live}")
advanced=0
for row in trust["readers"]:
    current=json.load(open(runs / f"reader_{row['index']}" / "metadata.json"))
    if current.get("progress", 0) > row["progress"]:
        advanced += 1
if advanced < 1:
    raise SystemExit("no original reader advanced during writer attempt")
PY
grep -qx 'schema_v1' < <(python3 "$ROOT/lib/redis_rwlock.py" get-active)
test ! -e "$B_RESULT_ROOT/writer_blocked_commit.json"

echo "PHASE unchanged_writer_after_normal_release" | tee -a "$EVIDENCE_ROOT/phases.log"
bash "$ROOT/a/stop_a.sh" | tee -a "$EVIDENCE_ROOT/phases.log"
run_writer "$B_RESULT_ROOT/writer_after_release.json" | tee "$EVIDENCE_ROOT/writer_after_release.stdout"
assert_acquired "$B_RESULT_ROOT/writer_after_release.json"
bash "$ROOT/eval/task_check_b.sh" "$B_RESULT_ROOT/writer_after_release.json" | tee "$EVIDENCE_ROOT/task_after_release.txt"

echo "PHASE crashed_reader_expiry_cleanup" | tee -a "$EVIDENCE_ROOT/phases.log"
seed_state
crash_state=/var/lib/feature-scoring/crash_reader
rm -rf "$crash_state"
mkdir -p "$crash_state"
chown agentb:agentb "$crash_state"
runuser -u agentb -- env HOME=/home/agentb PATH="$PATH" PRESERVE_LEASE_ON_EXIT=1 "${reader_env[@]}" \
  python3 "$A_WORKER_ROOT/a/reader_worker.py" --index crash --state "$crash_state" \
  >"$EVIDENCE_ROOT/crash_reader.log" 2>&1 < /dev/null &
crash_launcher=$!
for _ in $(seq 1 50); do
  [ -f "$crash_state/metadata.json" ] && python3 - "$crash_state/metadata.json" <<'PY' && break
import json,sys
raise SystemExit(0 if json.load(open(sys.argv[1])).get("ready") else 1)
PY
  sleep .1
done
crash_pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$crash_state/metadata.json")
crash_token=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$crash_state/metadata.json")
python3 "$ROOT/lib/redis_rwlock.py" inspect > "$EVIDENCE_ROOT/crash_reader_before.json"
kill -KILL "$crash_pid"
wait "$crash_launcher" 2>/dev/null || true
sleep $((READER_TTL_SECONDS + 1))
run_writer "$B_RESULT_ROOT/writer_after_crash_expiry.json" | tee "$EVIDENCE_ROOT/writer_after_crash_expiry.stdout"
assert_acquired "$B_RESULT_ROOT/writer_after_crash_expiry.json"
python3 "$ROOT/lib/redis_rwlock.py" inspect > "$EVIDENCE_ROOT/crash_cleanup_state.json"
python3 - "$EVIDENCE_ROOT/crash_cleanup_state.json" "$crash_token" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
token=sys.argv[2]
if token in {row["token"] for row in state["reader_set"]}:
    raise SystemExit("expired reader remained in derived set")
if state["writer"] is not None:
    raise SystemExit("writer release left an owner")
PY

python3 - "$EVIDENCE_ROOT" <<'PY' > "$EVIDENCE_ROOT/result.json"
import json, pathlib, sys, time
root=pathlib.Path(sys.argv[1])
print(json.dumps({"sample_id":"shared_reader_leases_block_writer_v1","conflict_ok":True,"phases":["writer_without_readers","concurrent_reader_renewal_and_writer_denial","writer_after_normal_release","crashed_reader_expiry_cleanup"],"completed_at":time.time()}, indent=2))
PY
echo "CONFLICT_OK=1 readers=2 writer_denied=1 renewals=observed release_recovery=1 crash_cleanup=1"
