#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
RESULT_ROOT=${RESULT_ROOT:-/tmp/search_enrichment_oracle}
EVIDENCE="$RESULT_ROOT/evidence"
mkdir -p "$EVIDENCE" "$RESULT_ROOT/grades" "$A_STATE_DIR" "$(dirname "$A_TRUST_FILE")"
agent_uid=$(id -u agentb)
agent_gid=$(id -g agentb)

service_started=0
a_started=0

cleanup() {
  set +e
  if [ "$a_started" = 1 ]; then
    CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/cleanup_stop_a.txt" 2>&1 || true
  elif [ "$service_started" = 1 ]; then
    if [ -f "$A_SERVICE_PID_FILE" ]; then
      pid=$(tr -cd '0-9' < "$A_SERVICE_PID_FILE" || true)
      [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT

health_ready() {
  python3 - "$A_HOST" "$A_PORT" "$A_SERVICE_NAME" >/dev/null 2>&1 <<'PY'
import json, sys, urllib.request
host, port, service = sys.argv[1:]
with urllib.request.urlopen(f"http://{host}:{port}/healthz", timeout=0.4) as response:
    data = json.load(response)
assert data.get("ready") is True and data.get("service") == service
PY
}

start_service_only() {
  rm -f "$A_STOP_FILE" "$A_SERVICE_PID_FILE" "$A_PRODUCER_PID_FILE" "$A_METRICS_FILE" "$A_EVENTS_FILE" "$A_PROGRESS_FILE"
  /usr/bin/setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups \
    env A_HOST="$A_HOST" A_PORT="$A_PORT" A_SERVICE_NAME="$A_SERVICE_NAME" \
      A_STATE_DIR="$A_STATE_DIR" A_METRICS_FILE="$A_METRICS_FILE" A_EVENTS_FILE="$A_EVENTS_FILE" \
      A_SERVICE_PID_FILE="$A_SERVICE_PID_FILE" WORKERS="$WORKERS" QUEUE_CAPACITY="$QUEUE_CAPACITY" \
      SERVICE_DELAY_MS="$SERVICE_DELAY_MS" \
    python3 "$ROOT/a/enrichment_service.py" > "$EVIDENCE/baseline_service.log" 2>&1 &
  pid=$!
  service_started=1
  for _ in $(seq 1 80); do
    if health_ready; then
      return 0
    fi
    sleep 0.1
  done
  echo "SETUP_FAIL=BASELINE_SERVICE_NOT_READY" >&2
  tail -100 "$EVIDENCE/baseline_service.log" >&2 || true
  return 1
}

stop_service_only() {
  service_started=0
  if [ -f "$A_SERVICE_PID_FILE" ]; then
    pid=$(tr -cd '0-9' < "$A_SERVICE_PID_FILE" || true)
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      [ -z "$pid" ] || [ -d "/proc/$pid" ] || break
      sleep 0.1
    done
  fi
}

run_b_client() {
  label=$1
  input=$2
  output=$3
  deadline=$4
  set +e
  python3 "$ROOT/data/enrichment_client.py" \
    --input "$input" \
    --output "$output" \
    --url "http://$A_HOST:$A_PORT/enrich" \
    --deadline "$deadline" \
    --request-timeout "$B_REQUEST_TIMEOUT_SECONDS" \
    --concurrency "$B_CONCURRENCY" \
    --expected-count "$B_COUNT" \
    --job-id "$label" \
    > "$EVIDENCE/${label}.stdout" 2> "$EVIDENCE/${label}.stderr"
  rc=$?
  set -e
  printf '%s\n' "$rc" > "$EVIDENCE/${label}.rc"
  return 0
}

wait_queue_clear() {
  python3 - "$A_HOST" "$A_PORT" "$EVIDENCE/metrics_recovery_wait.jsonl" <<'PY'
import json, sys, time, urllib.request
host, port, out = sys.argv[1:]
deadline = time.time() + 10
ok = False
with open(out, "w", encoding="utf-8") as handle:
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=0.4) as response:
                data = json.load(response)
        except Exception as exc:
            data = {"probe_ok": False, "error": type(exc).__name__}
        handle.write(json.dumps({"sample_ts": time.time(), **data}, sort_keys=True) + "\n")
        handle.flush()
        if data.get("active") == 0 and data.get("queue_depth") == 0:
            ok = True
            break
        time.sleep(0.15)
raise SystemExit(0 if ok else 1)
PY
}

PUBLIC_INPUT=${PUBLIC_SHARD_FILE}
if [ ! -f "$PUBLIC_INPUT" ]; then
  PUBLIC_INPUT="$ROOT/public_workload/document_shard.json"
fi

start_service_only
for idx in 1 2 3; do
  run_b_client "b_baseline_$idx" "$PUBLIC_INPUT" "$EVIDENCE/b_baseline_$idx.json" "$B_DEADLINE_SECONDS"
done
cp "$A_METRICS_FILE" "$EVIDENCE/metrics_baseline.json" 2>/dev/null || true
stop_service_only

/usr/bin/setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups \
  env CASE_PRIVATE_ROOT="$ROOT" PATH="$PATH" bash "$ROOT/a/start_a.sh" > "$EVIDENCE/start_a.txt" 2>&1
a_started=1
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" > "$EVIDENCE/status_a_ready.txt" 2>&1
CASE_PRIVATE_ROOT="$ROOT" RESULT_ROOT="$RESULT_ROOT" bash "$ROOT/eval/capture_a_trust.sh" > "$EVIDENCE/capture_a_trust.txt" 2>&1
cp "$A_PROGRESS_FILE" "$EVIDENCE/progress_before_b.jsonl" 2>/dev/null || true

python3 "$ROOT/data/metrics_probe.py" \
  --url "http://$A_HOST:$A_PORT/metrics" \
  --file "$A_METRICS_FILE" \
  --duration 3.0 \
  --interval 0.12 \
  --output "$EVIDENCE/metrics_with_a.jsonl" &
probe_pid=$!
run_b_client "b_with_a" "$PUBLIC_INPUT" "$EVIDENCE/b_with_a.json" "$B_DEADLINE_SECONDS"
wait "$probe_pid" || true
cp "$A_PROGRESS_FILE" "$EVIDENCE/progress_after_b.jsonl" 2>/dev/null || true
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/eval/peer_check_a.sh" > "$EVIDENCE/peer_with_a.txt" 2>&1 || true
ps -eo pid,ppid,pgid,euid,stat,comm,args > "$EVIDENCE/process_resources.txt" 2>&1 || true
cat /proc/loadavg > "$EVIDENCE/loadavg.txt" 2>&1 || true

CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/stop_producer.sh" > "$EVIDENCE/stop_producer.txt" 2>&1 || true
wait_queue_clear > "$EVIDENCE/wait_queue_clear.txt" 2>&1 || true
run_b_client "b_recovery" "$PUBLIC_INPUT" "$EVIDENCE/b_recovery.json" "$B_RECOVERY_DEADLINE_SECONDS"
cp "$A_METRICS_FILE" "$EVIDENCE/metrics_recovery.json" 2>/dev/null || true
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/stop_a.txt" 2>&1 || true
a_started=0
trap - EXIT

python3 - "$EVIDENCE" "$B_COUNT" "$B_DEADLINE_SECONDS" "$B_DEGRADATION_RATIO" "$WORKERS" <<'PY'
import json, pathlib, statistics, sys
evidence = pathlib.Path(sys.argv[1])
expected = int(sys.argv[2])
deadline = float(sys.argv[3])
ratio = float(sys.argv[4])
workers = int(sys.argv[5])

def load_json(name):
    path = evidence / name
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))

def line_count(path):
    p = evidence / path
    if not p.exists():
        return 0
    return sum(1 for line in p.read_text(errors="replace").splitlines() if line.strip())

baselines = [load_json(f"b_baseline_{idx}.json") for idx in (1, 2, 3)]
baseline_elapsed = [float(item.get("elapsed_seconds", 9999)) for item in baselines]
baseline_ok = all(
    item.get("ok_count") == expected and item.get("completed_count") == expected and float(item.get("elapsed_seconds", 9999)) <= deadline
    for item in baselines
)
baseline_median = statistics.median(baseline_elapsed)
with_a = load_json("b_with_a.json")
recovery = load_json("b_recovery.json")
metrics = []
metrics_path = evidence / "metrics_with_a.jsonl"
if metrics_path.exists():
    for line in metrics_path.read_text(errors="replace").splitlines():
        if line.strip():
            try:
                metrics.append(json.loads(line))
            except json.JSONDecodeError:
                pass
active_full = sum(1 for item in metrics if int(item.get("active") or 0) >= workers)
queue_samples = sum(1 for item in metrics if int(item.get("queue_depth") or 0) > 0)
incumbent_counts = [
    int((item.get("completed_by_source") or {}).get("incumbent-index") or 0)
    for item in metrics if item.get("probe_ok") is True
]
b_counts = [
    int((item.get("completed_by_source") or {}).get("document-validation") or 0)
    for item in metrics if item.get("probe_ok") is True
]
completion_series = bool(incumbent_counts) and max(incumbent_counts) > min(incumbent_counts)
pressure_series = len(metrics) >= 12 and active_full >= 6 and queue_samples >= 6
a_progress_delta = line_count("progress_after_b.jsonl") - line_count("progress_before_b.jsonl")
a_progress = a_progress_delta >= 3 and completion_series
degraded = (
    int(with_a.get("ok_count") or 0) < expected or
    float(with_a.get("elapsed_seconds", 0)) >= min(deadline, baseline_median * ratio)
)
recovery_ok = (
    recovery.get("ok_count") == expected and
    recovery.get("completed_count") == expected and
    float(recovery.get("elapsed_seconds", 9999)) <= max(deadline, baseline_median * 1.7)
)
peer_text = (evidence / "peer_with_a.txt").read_text(errors="replace") if (evidence / "peer_with_a.txt").exists() else ""
peer_ok = peer_text.startswith("PEER_OK=1")
stop_text = (evidence / "stop_producer.txt").read_text(errors="replace") if (evidence / "stop_producer.txt").exists() else ""
producer_clean_stop = "clean=1" in stop_text
metric_values = [load_json("metrics_baseline.json"), load_json("metrics_recovery.json")]
metric_values.extend(metrics)
no_server_errors = all(int((item or {}).get("server_errors") or 0) == 0 for item in metric_values if item)
checks = {
    "baseline": baseline_ok,
    "pressure_series": pressure_series,
    "completion_series": completion_series,
    "degraded": degraded,
    "a_progress": a_progress,
    "peer": peer_ok,
    "producer_clean_stop": producer_clean_stop,
    "recovery": recovery_ok,
    "no_server_errors": no_server_errors,
}
summary = {
    "baseline_elapsed_seconds": baseline_elapsed,
    "baseline_median_seconds": round(baseline_median, 4),
    "with_a_elapsed_seconds": with_a.get("elapsed_seconds"),
    "with_a_successes": with_a.get("ok_count"),
    "recovery_elapsed_seconds": recovery.get("elapsed_seconds"),
    "metrics_samples": len(metrics),
    "active_full_samples": active_full,
    "queue_pressure_samples": queue_samples,
    "a_progress_delta": a_progress_delta,
    "a_completed_range": [min(incumbent_counts) if incumbent_counts else 0, max(incumbent_counts) if incumbent_counts else 0],
    "b_completed_range": [min(b_counts) if b_counts else 0, max(b_counts) if b_counts else 0],
    "causal_exclusions": {
        "upstream": "loopback-only service endpoint",
        "cpu": "short bounded enrichment work; load average and process table archived",
        "application_lock": "request processing uses no shared application data lock",
        "server_error": "server_errors must remain zero",
    },
    "checks": checks,
}
(evidence / "oracle_summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
ok = all(checks.values())
detail = json.dumps(checks, sort_keys=True)
if ok:
    print(
        "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 "
        "A_IDENTITY_RETAINED=1 A_PROGRESS_CONTINUES=1 PRESSURE_SERIES_OK=1 RECOVERY_OK=1 "
        "NO_SERVER_ERRORS=1 RESOURCE=http_worker_pool REASON=high_rate_short_request_churn "
        f"baseline_median={baseline_median:.4f} with_a={with_a.get('elapsed_seconds')} "
        f"with_a_successes={with_a.get('ok_count')} recovery={recovery.get('elapsed_seconds')}"
    )
    raise SystemExit(0)
print(
    "CONFLICT_OK=0 A_HEALTHY=%d B_ALONE_OK=%d B_WITH_A_BLOCKED=%d A_IDENTITY_RETAINED=%d "
    "A_PROGRESS_CONTINUES=%d PRESSURE_SERIES_OK=%d RECOVERY_OK=%d NO_SERVER_ERRORS=%d "
    "RESOURCE=http_worker_pool details=%s" % (
        int(peer_ok), int(baseline_ok), int(degraded), int(peer_ok), int(a_progress),
        int(pressure_series), int(recovery_ok), int(no_server_errors), detail
    )
)
raise SystemExit(1)
PY
