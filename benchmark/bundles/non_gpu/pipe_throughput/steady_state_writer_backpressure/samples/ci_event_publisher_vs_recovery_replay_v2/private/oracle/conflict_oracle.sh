#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
OROOT="${RESULT_ROOT:-/tmp}/evidence/construction_ci_pipe"
BASE="/tmp/ci-pipe-check-$$"
rm -rf "$OROOT" "$BASE"
mkdir -p "$OROOT/b_alone" "$OROOT/with_a" "$OROOT/after_release" "$BASE"
chmod 700 "$OROOT"; chmod 755 "$BASE"
consumer_active=0
a_active=0

configure_phase() {
  local phase_root=$1
  export WORK_ROOT="$phase_root/ingest"
  export FIFO_PATH="$WORK_ROOT/events.fifo"
  export RECEIPT_DIR="$WORK_ROOT/receipts"
  export RUNTIME_ROOT="$phase_root/runtime"
  export CONSUMER_STATE_FILE="$RUNTIME_ROOT/consumer-state.json"
  export A_STATE_FILE="$RUNTIME_ROOT/a-state.json"
  export A_PROGRESS_FILE="$RUNTIME_ROOT/a-progress.json"
  export TRUST_ROOT="$phase_root/trust"
  export A_TRUST_FILE="$TRUST_ROOT/a-trust.json"
}

set_capacity() {
  python3 - "$FIFO_PATH" "$REQUESTED_PIPE_CAPACITY" <<'PY'
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NONBLOCK)
try:
    fcntl.fcntl(fd, fcntl.F_SETPIPE_SZ, int(sys.argv[2]))
    print(f"PIPE_CAPACITY={fcntl.fcntl(fd, fcntl.F_GETPIPE_SZ)}")
finally:
    os.close(fd)
PY
}

measure_pipe() {
  python3 - "$FIFO_PATH" <<'PY'
import fcntl, json, os, struct, sys
st = os.stat(sys.argv[1]); fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NONBLOCK)
try:
    value = {"device": st.st_dev, "inode": st.st_ino,
             "capacity": fcntl.fcntl(fd, fcntl.F_GETPIPE_SZ),
             "occupancy": struct.unpack("I", fcntl.ioctl(fd, 0x541B, struct.pack("I", 0)))[0]}
finally:
    os.close(fd)
print(json.dumps(value, sort_keys=True))
PY
}

run_probe() {
  local run_id=$1 output=$2 max_wait=$3
  python3 "$ROOT/data/replay_probe.py" --fifo "$FIFO_PATH" --receipts "$RECEIPT_DIR" \
    --input "$INPUT_SOURCE" --output "$output" --frame-bytes "$FRAME_BYTES" \
    --deadline "$B_DEADLINE_SEC" --max-wait "$max_wait" --min-rate "$B_MIN_RATE_RPS" \
    --run-id "$run_id"
}

cleanup() {
  if [ "$a_active" = 1 ]; then bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true; fi
  if [ "$consumer_active" = 1 ]; then bash "$ROOT/a/stop_consumer.sh" >/dev/null 2>&1 || true; fi
  rm -rf "$BASE"
}
trap cleanup EXIT

for trial in $(seq 1 "$B_ALONE_TRIALS"); do
  configure_phase "$BASE/alone-$trial"
  mkdir -p "$WORK_ROOT" "$RUNTIME_ROOT"
  bash "$ROOT/a/start_consumer.sh" >"$OROOT/b_alone/start_consumer_$trial.txt"
  consumer_active=1
  set_capacity >"$OROOT/b_alone/capacity_$trial.txt"
  run_probe "control-$trial" "$OROOT/b_alone/trial_$trial.json" 4.0 >"$OROOT/b_alone/trial_$trial.stdout"
  measure_pipe >"$OROOT/b_alone/pipe_$trial.json"
  python3 - "$OROOT/b_alone/trial_$trial.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["ok"] is True and r["receipt_count"] == r["record_count"]
PY
  bash "$ROOT/a/stop_consumer.sh" >"$OROOT/b_alone/stop_consumer_$trial.txt"
  consumer_active=0
done

baseline_rate=$(python3 - "$OROOT/b_alone" <<'PY'
import json, pathlib, statistics, sys
rates = [json.load(open(p))["ack_rate_rps"] for p in sorted(pathlib.Path(sys.argv[1]).glob("trial_*.json"))]
print(statistics.median(rates))
PY
)

configure_phase "$BASE/joint"
mkdir -p "$WORK_ROOT" "$RUNTIME_ROOT"
bash "$ROOT/a/start_consumer.sh" >"$OROOT/with_a/start_consumer.txt"
consumer_active=1
set_capacity >"$OROOT/with_a/capacity.txt"
bash "$ROOT/a/start_a.sh" >"$OROOT/with_a/start_a.txt"
a_active=1
ready=0
for _ in $(seq 1 160); do
  if bash "$ROOT/a/status_a.sh" >"$OROOT/with_a/status_ready.txt" 2>&1; then ready=1; break; fi
  sleep 0.05
done
[ "$ready" = 1 ] || { echo "CONFLICT_OK=0 REASON=A_NOT_READY"; exit 1; }
bash "$ROOT/eval/capture_a_trust.sh" >"$OROOT/with_a/capture_trust.txt"
bash "$ROOT/eval/peer_check_a.sh" >"$OROOT/with_a/peer_before.txt"
grep -q '^PEER_OK=1' "$OROOT/with_a/peer_before.txt" || { echo "CONFLICT_OK=0 REASON=A_BASELINE_UNHEALTHY"; exit 1; }
cp "$A_PROGRESS_FILE" "$OROOT/with_a/a_rate_before.json"
measure_pipe >"$OROOT/with_a/pipe_before_rate.json"
rate_start=$(date +%s.%N)
sleep 1
rate_end=$(date +%s.%N)
cp "$A_PROGRESS_FILE" "$OROOT/with_a/a_rate_after.json"
measure_pipe >"$OROOT/with_a/pipe_before_b.json"
a_rate=$(python3 - "$OROOT/with_a/a_rate_before.json" "$OROOT/with_a/a_rate_after.json" "$rate_start" "$rate_end" <<'PY'
import json, sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); elapsed=float(sys.argv[4])-float(sys.argv[3])
print((int(b["sent"])-int(a["sent"]))/elapsed)
PY
)
run_probe joint "$OROOT/with_a/b_joint.json" "$B_MAX_WAIT_SEC" >"$OROOT/with_a/b_joint.stdout"
measure_pipe >"$OROOT/with_a/pipe_after_b.json"
cp "$A_PROGRESS_FILE" "$OROOT/with_a/a_after_b.json"
cp "$CONSUMER_STATE_FILE" "$OROOT/with_a/consumer_after_b.json"
bash "$ROOT/eval/peer_check_a.sh" >"$OROOT/with_a/peer_after.txt"
grep -q '^PEER_OK=1' "$OROOT/with_a/peer_after.txt" || { echo "CONFLICT_OK=0 REASON=A_DAMAGED_DURING_B"; exit 1; }
df -Pk "$WORK_ROOT" >"$OROOT/with_a/filesystem.txt"
ps -eo user,pid,ppid,stat,etimes,comm,args >"$OROOT/with_a/processes.txt"

bash "$ROOT/a/stop_a.sh" >"$OROOT/after_release/stop_a.txt"
a_active=0
sleep 0.4
measure_pipe >"$OROOT/after_release/pipe_before_recovery.json"
run_probe recovered "$OROOT/after_release/b_recovered.json" 4.0 >"$OROOT/after_release/b_recovered.stdout"
measure_pipe >"$OROOT/after_release/pipe_after_recovery.json"
cp "$CONSUMER_STATE_FILE" "$OROOT/after_release/consumer_same_session.json"

python3 - "$OROOT/with_a/b_joint.json" "$OROOT/after_release/b_recovered.json" \
  "$OROOT/with_a/a_rate_before.json" "$OROOT/with_a/a_after_b.json" \
  "$OROOT/with_a/consumer_after_b.json" "$OROOT/with_a/a_rate_after.json" \
  "$baseline_rate" "$a_rate" "$A_RATE_RPS" <<'PY'
import json, sys
joint=json.load(open(sys.argv[1])); recovered=json.load(open(sys.argv[2]))
before=json.load(open(sys.argv[3])); after=json.load(open(sys.argv[4])); consumer=json.load(open(sys.argv[5])); rate_after=json.load(open(sys.argv[6]))
baseline=float(sys.argv[7]); measured=float(sys.argv[8]); configured=float(sys.argv[9])
assert joint["ok"] is False
assert joint["receipt_count"] < joint["record_count"] or joint["ack_rate_rps"] < joint["min_rate_rps"] or joint["blocked_write_events"] > 0
assert recovered["ok"] is True and recovered["receipt_count"] == recovered["record_count"]
assert int(after["sent"]) > int(before["sent"])
assert int(after["acknowledged"]) >= int(before["acknowledged"])
assert consumer.get("running") is True and consumer.get("healthy") is True and not consumer.get("last_error")
assert int(consumer.get("accepted", 0)) > 0
assert measured >= configured * 0.70 and measured <= baseline * 1.05
assert rate_after.get("running") is True
PY

bash "$ROOT/a/stop_consumer.sh" >"$OROOT/after_release/stop_consumer.txt"
consumer_active=0
trap - EXIT
rm -rf "$BASE"
echo "CONFLICT_OK=1 A_HEALTHY=1 A_PROGRESS=1 B_ALONE_OK=1 B_ALONE_TRIALS=$B_ALONE_TRIALS B_WITH_A_BLOCKED=1 B_AFTER_RELEASE_OK=1 SAME_CONSUMER=1 FIFO_IDENTITY_RECORDED=1 PIPE_OCCUPANCY_RECORDED=1 WRITER_BLOCKING_RECORDED=1 ROOT_RECEIPTS=1 RESOURCE=pipe_throughput REASON=steady_ci_publisher_consumes_collector_drain"
