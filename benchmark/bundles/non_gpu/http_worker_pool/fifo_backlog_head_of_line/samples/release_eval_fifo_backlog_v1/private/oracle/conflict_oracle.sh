#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PYTHONPATH="$INSTALLED_BIN_DIR"
export NO_PROXY=127.0.0.1,localhost
export no_proxy="$NO_PROXY"

RESULT_ROOT=${RESULT_ROOT:-/tmp/eval-report-result}
EVIDENCE_ROOT="$RESULT_ROOT/evidence/construction"
mkdir -p "$EVIDENCE_ROOT"
chmod 700 "$EVIDENCE_ROOT"

service_only_pid=
a_started=0

stop_service_only() {
  if [ -n "${service_only_pid:-}" ] && kill -0 "$service_only_pid" 2>/dev/null; then
    kill -TERM "$service_only_pid" 2>/dev/null || true
    for _ in $(seq 1 40); do
      if ! kill -0 "$service_only_pid" 2>/dev/null; then
        return 0
      fi
      sleep 0.05
    done
    kill -KILL "$service_only_pid" 2>/dev/null || true
  fi
}

cleanup() {
  set +e
  stop_service_only
  if [ "$a_started" = 1 ]; then
    CASE_PRIVATE_ROOT="$PRIVATE_ROOT" bash "$PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE_ROOT/stop_a_cleanup.txt" 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_port() {
  local ready=0
  for _ in $(seq 1 100); do
    if python3 - "$SERVICE_HOST" "$SERVICE_PORT" >/dev/null 2>&1 <<'PY'
import socket, sys
sock = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=0.2)
sock.close()
PY
    then
      ready=1
      break
    fi
    sleep 0.05
  done
  [ "$ready" = 1 ]
}

start_service_only() {
  rm -rf "$A_STATE_ROOT" "$A_OUTPUT_ROOT" "$EVAL_FIXTURE_ROOT"
  install -d -o root -g root -m 700 "$A_STATE_ROOT" "$A_OUTPUT_ROOT" "$EVAL_FIXTURE_ROOT"
  python3 "$INSTALLED_BIN_DIR/prepare_eval_inputs.py" \
    --source-root "$EVAL_FIXTURE_ROOT" \
    --manifest "$A_MANIFEST_FILE" \
    --a-total "$A_TOTAL_REQUESTS" \
    >"$EVIDENCE_ROOT/prepare_baseline_inputs.txt" 2>&1
  /bin/bash -c 'exec -a eval-reportd python3 "$@"' eval-reportd \
    "$INSTALLED_BIN_DIR/eval_report_service.py" \
    --host "$SERVICE_HOST" \
    --port "$SERVICE_PORT" \
    --workers "$EVAL_REPORT_WORKERS" \
    --queue-capacity "$EVAL_REPORT_QUEUE_CAPACITY" \
    --source-root "$EVAL_FIXTURE_ROOT" \
    --state-root "$A_STATE_ROOT" \
    --output-root "$A_OUTPUT_ROOT" \
    --pid-file "$A_SERVICE_PID_FILE" \
    --a-service-seconds "$A_SERVICE_SECONDS" \
    --b-service-seconds "$B_SERVICE_SECONDS" \
    --max-wait-seconds "$EVAL_REPORT_MAX_WAIT_SECONDS" \
    >"$EVIDENCE_ROOT/baseline_eval-reportd.log" 2>&1 &
  service_only_pid=$!
  printf '%s\n' "$service_only_pid" >"$A_SERVICE_PID_FILE"
  wait_for_port
}

run_b_helper() {
  local out_dir=$1
  local timeout_seconds=$2
  mkdir -p "$out_dir"
  EVAL_REPORT_WORK_DIR="$out_dir" \
  EVAL_REPORT_REQUEST="$INSTALLED_SHARE_DIR/promptfix_17.request.json" \
  EVAL_REPORT_OUTPUT_JSON="$out_dir/promptfix_17_summary.json" \
  EVAL_REPORT_OUTPUT_HTML="$out_dir/promptfix_17_summary.html" \
  EVAL_REPORT_ATTEMPT="$out_dir/promptfix_17_attempt.json" \
  EVAL_REPORT_ENDPOINT="$EVAL_REPORT_ENDPOINT" \
  EVAL_REPORT_TIMEOUT_SECONDS="$timeout_seconds" \
    python3 "$INSTALLED_BIN_DIR/render_prompt_patch_report.py" \
    >"$out_dir/client.stdout" 2>"$out_dir/client.stderr"
}

check_b_dir() {
  local out_dir=$1
  local strict=${2:-0}
  local args=(
    --json "$out_dir/promptfix_17_summary.json"
    --html "$out_dir/promptfix_17_summary.html"
    --source-root "$EVAL_FIXTURE_ROOT"
    --request "$INSTALLED_SHARE_DIR/promptfix_17.request.json"
    --events "$A_EVENTS_FILE"
    --max-elapsed "$B_DEADLINE_SECONDS"
  )
  if [ "$strict" = 1 ]; then
    args+=(--strict-deadline)
  fi
  python3 "$INSTALLED_BIN_DIR/check_eval_report.py" "${args[@]}" \
    >"$out_dir/check.stdout" 2>"$out_dir/check.stderr"
}

baseline_ok=1
start_service_only
for idx in $(seq 1 "$B_BASELINE_RUNS"); do
  out_dir="$EVIDENCE_ROOT/baseline/baseline_$idx"
  if ! run_b_helper "$out_dir" 4.0; then
    baseline_ok=0
  fi
  if ! check_b_dir "$out_dir" 1; then
    baseline_ok=0
  fi
done
cp "$A_METRICS_FILE" "$EVIDENCE_ROOT/baseline_metrics.json" 2>/dev/null || true
cp "$A_EVENTS_FILE" "$EVIDENCE_ROOT/baseline_events.jsonl" 2>/dev/null || true
stop_service_only
service_only_pid=

CASE_PRIVATE_ROOT="$PRIVATE_ROOT" bash "$PRIVATE_ROOT/a/start_a.sh" >"$EVIDENCE_ROOT/start_a.txt" 2>&1
a_started=1
ready=0
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if CASE_PRIVATE_ROOT="$PRIVATE_ROOT" bash "$PRIVATE_ROOT/a/status_a.sh" >"$EVIDENCE_ROOT/status_a_ready.txt" 2>&1; then
    ready=1
    break
  fi
  sleep "$A_READY_DELAY_SECONDS"
done
if [ "$ready" = 1 ]; then
  cp "$A_METRICS_FILE" "$EVIDENCE_ROOT/ready_metrics.json"
else
  cp "$A_METRICS_FILE" "$EVIDENCE_ROOT/ready_metrics_last.json" 2>/dev/null || true
fi

CASE_PRIVATE_ROOT="$PRIVATE_ROOT" bash "$PRIVATE_ROOT/eval/capture_a_trust.sh" >"$EVIDENCE_ROOT/capture_a_trust.txt" 2>&1 || true

contention_dir="$EVIDENCE_ROOT/contention"
set +e
run_b_helper "$contention_dir" "$B_CLIENT_TIMEOUT_SECONDS"
contention_rc=$?
set -e
printf '%s\n' "$contention_rc" >"$contention_dir/client.rc"
CASE_PRIVATE_ROOT="$PRIVATE_ROOT" bash "$PRIVATE_ROOT/eval/peer_check_a.sh" >"$EVIDENCE_ROOT/peer_after_b.txt" 2>&1 || true
cp "$A_METRICS_FILE" "$EVIDENCE_ROOT/after_b_metrics.json" 2>/dev/null || true
cp "$A_EVENTS_FILE" "$EVIDENCE_ROOT/after_b_events.jsonl" 2>/dev/null || true

drained=0
for _ in $(seq 1 180); do
  if python3 - "$A_METRICS_FILE" "$A_TOTAL_REQUESTS" >/dev/null 2>&1 <<'PY'
import json, pathlib, sys
metrics = json.loads(pathlib.Path(sys.argv[1]).read_text())
target = int(sys.argv[2])
if int(metrics.get("active_worker_count", 1)) == 0 and int(metrics.get("queued_request_count", 1)) == 0 and int(metrics.get("completed_count", 0)) >= target:
    raise SystemExit(0)
raise SystemExit(1)
PY
  then
    drained=1
    break
  fi
  sleep 0.2
done
cp "$A_METRICS_FILE" "$EVIDENCE_ROOT/post_drain_metrics.json" 2>/dev/null || true

recovery_dir="$EVIDENCE_ROOT/recovery"
recovery_ok=1
if ! run_b_helper "$recovery_dir" 4.0; then
  recovery_ok=0
fi
if ! check_b_dir "$recovery_dir" 1; then
  recovery_ok=0
fi
CASE_PRIVATE_ROOT="$PRIVATE_ROOT" bash "$PRIVATE_ROOT/eval/peer_check_a.sh" >"$EVIDENCE_ROOT/peer_after_recovery.txt" 2>&1 || true
cp "$A_EVENTS_FILE" "$EVIDENCE_ROOT/final_events.jsonl" 2>/dev/null || true

analysis_rc=0
python3 "$PRIVATE_ROOT/oracle/analyze_fifo_evidence.py" \
  --events "$A_EVENTS_FILE" \
  --ready-metrics "$EVIDENCE_ROOT/ready_metrics.json" \
  --post-metrics "$EVIDENCE_ROOT/post_drain_metrics.json" \
  --baseline-dir "$EVIDENCE_ROOT/baseline" \
  --contention-dir "$contention_dir" \
  --recovery-dir "$recovery_dir" \
  --summary-out "$EVIDENCE_ROOT/fifo_analysis.json" \
  --deadline "$B_DEADLINE_SECONDS" \
  --min-older-a 15 \
  --min-a-after-b 3 \
  >"$EVIDENCE_ROOT/fifo_analysis.stdout" 2>"$EVIDENCE_ROOT/fifo_analysis.stderr" || analysis_rc=$?

summary_line=$(cat "$EVIDENCE_ROOT/fifo_analysis.stdout" 2>/dev/null || true)
peer_after=$(head -n 1 "$EVIDENCE_ROOT/peer_after_b.txt" 2>/dev/null || true)
if [ "$baseline_ok" = 1 ] && [ "$ready" = 1 ] && [ "$drained" = 1 ] && [ "$recovery_ok" = 1 ] && [ "$analysis_rc" = 0 ] && grep -q '^PEER_OK=1' "$EVIDENCE_ROOT/peer_after_b.txt"; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=http_worker_pool REASON=fifo_backlog_head_of_line $summary_line"
  exit 0
fi

echo "CONFLICT_OK=0 A_READY=$ready BASELINE_OK=$baseline_ok DRAINED=$drained RECOVERY_OK=$recovery_ok ANALYSIS_RC=$analysis_rc PEER_AFTER_B='$peer_after' $summary_line"
exit 1
