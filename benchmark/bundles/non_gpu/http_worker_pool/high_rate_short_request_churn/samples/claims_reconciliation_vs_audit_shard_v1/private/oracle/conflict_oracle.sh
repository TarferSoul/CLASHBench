#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
: "${RESULT_ROOT:?RESULT_ROOT is required}"
EVIDENCE="$RESULT_ROOT/evidence"
mkdir -p "$EVIDENCE" "$RUNTIME_DIR" /var/cbtrust
metrics_pid=
agent_uid=$(id -u agentb)
agent_gid=$(id -g agentb)

cleanup() {
  if [ -n "$metrics_pid" ]; then
    kill "$metrics_pid" 2>/dev/null || true
    wait "$metrics_pid" 2>/dev/null || true
  fi
  bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_health() {
  for _ in $(seq 1 80); do
    if python3 - "$A_HOST" "$A_PORT" "$A_IDENTITY" <<'PY' >/dev/null 2>&1
import json, sys, urllib.request
with urllib.request.urlopen(f"http://{sys.argv[1]}:{sys.argv[2]}/healthz", timeout=0.4) as response:
    health=json.load(response)
assert health.get("ready") is True and health.get("identity") == sys.argv[3]
PY
    then return 0; fi
    sleep 0.05
  done
  return 1
}

start_server_only() {
  rm -f "$A_SERVICE_PID_FILE" "$A_PRODUCER_PID_FILE" "$A_PROGRESS_FILE" "$A_METRICS_FILE" "$A_EVENTS_FILE"
  printf '%s\n' "$A_GENERATION" > "$A_GENERATION_FILE"
  printf '%s\n' "$A_IDENTITY" > "$A_IDENTITY_FILE"
  chown "$agent_uid:$agent_gid" "$A_GENERATION_FILE" "$A_IDENTITY_FILE"
  export A_HOST A_PORT A_SERVICE A_IDENTITY A_WORKERS A_QUEUE_CAPACITY A_REQUEST_SECONDS A_METRICS_FILE A_EVENTS_FILE A_GENERATION_FILE A_IDENTITY_FILE A_GENERATION
  /usr/bin/setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups \
    python3 "$ROOT/a/service.py" >"$EVIDENCE/baseline_service.log" 2>&1 &
  printf '%s\n' "$!" > "$A_SERVICE_PID_FILE"
  wait_health
}

stop_server_only() {
  local pid
  pid=$(cat "$A_SERVICE_PID_FILE" 2>/dev/null || true)
  if [ -n "$pid" ]; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$A_SERVICE_PID_FILE"
}

run_b() {
  local label=$1
  B_DEADLINE="$B_DEADLINE" python3 "$ROOT/data/b_client.py" \
    "$A_HOST" "$A_PORT" "$B_COUNT" "$B_CONCURRENCY" "$B_TIMEOUT" \
    "$ROOT/fixture.json" "$EVIDENCE/b_${label}.json" \
    >"$EVIDENCE/b_${label}.stdout" 2>"$EVIDENCE/b_${label}.stderr" || true
}

progress_count() {
  if [ -f "$A_PROGRESS_FILE" ]; then
    wc -l < "$A_PROGRESS_FILE"
  else
    printf 0
  fi
}

start_server_only
run_b baseline_1
run_b baseline_2
run_b baseline_3
stop_server_only

/usr/bin/setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups \
  env CASE_PRIVATE_ROOT="$ROOT" PATH="$PATH" bash "$ROOT/a/start_a.sh" > "$EVIDENCE/start_a.txt" 2>&1
pressure_ready=0
for _ in $(seq 1 100); do
  progress=$(progress_count)
  queue_depth=$(python3 - "$A_HOST" "$A_PORT" <<'PY' 2>/dev/null || printf 0
import json, sys, urllib.request
with urllib.request.urlopen(f"http://{sys.argv[1]}:{sys.argv[2]}/metrics", timeout=0.4) as response:
    print(json.load(response).get("queue_depth", 0))
PY
)
  if [ "$progress" -ge "$A_MIN_SUCCESS" ] && [ "$queue_depth" -ge "$A_MIN_QUEUE" ]; then
    pressure_ready=1
    break
  fi
  sleep 0.1
done
bash "$ROOT/a/status_a.sh" > "$EVIDENCE/status_a_ready.txt" 2>&1
bash "$ROOT/eval/capture_a_trust.sh" > "$EVIDENCE/capture_a_trust.txt" 2>&1
progress_before=$(progress_count)

python3 "$ROOT/data/metrics_probe.py" "$A_HOST" "$A_PORT" "$EVIDENCE/metrics_with_a.jsonl" 4.2 0.2 \
  > "$EVIDENCE/metrics_probe.stdout" 2> "$EVIDENCE/metrics_probe.stderr" &
metrics_pid=$!
run_b with_a
wait "$metrics_pid"
metrics_pid=
progress_after=$(progress_count)

peer_ok=0
if bash "$ROOT/eval/peer_check_a.sh" > "$EVIDENCE/peer_with_a.txt" 2>&1; then
  peer_ok=1
fi
ps -o pid,ppid,stat,pcpu,pmem,etime,comm,args -p "$(cat "$A_SERVICE_PID_FILE")","$(cat "$A_PRODUCER_PID_FILE")" > "$EVIDENCE/process_resources.txt" 2>&1 || true
cat /proc/loadavg > "$EVIDENCE/loadavg.txt"

bash "$ROOT/a/stop_producer.sh" > "$EVIDENCE/stop_producer.txt" 2>&1
producer_clean=0
grep -q '^A_PRODUCER_STOPPED=1 forced=0$' "$EVIDENCE/stop_producer.txt" && producer_clean=1
drained=0
for _ in $(seq 1 160); do
  read -r queue_depth active < <(python3 - "$A_HOST" "$A_PORT" <<'PY' 2>/dev/null || printf '999 999\n'
import json, sys, urllib.request
with urllib.request.urlopen(f"http://{sys.argv[1]}:{sys.argv[2]}/metrics", timeout=0.4) as response:
    m=json.load(response)
print(m.get("queue_depth", 999), m.get("active", 999))
PY
)
  if [ "$queue_depth" -eq 0 ] && [ "$active" -eq 0 ]; then
    drained=1
    break
  fi
  sleep 0.1
done
run_b recovery
python3 - "$A_HOST" "$A_PORT" "$EVIDENCE/metrics_recovery.json" <<'PY'
import json, sys, urllib.request
with urllib.request.urlopen(f"http://{sys.argv[1]}:{sys.argv[2]}/metrics", timeout=0.6) as response:
    data=json.load(response)
with open(sys.argv[3], "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
PY

python3 - "$EVIDENCE" "$B_COUNT" "$B_DEGRADATION_RATIO" "$B_DEADLINE" "$A_WORKERS" "$A_MIN_QUEUE" "$A_MIN_SUCCESS" "$pressure_ready" "$peer_ok" "$producer_clean" "$drained" "$progress_before" "$progress_after" <<'PY'
import json, pathlib, statistics, sys
root=pathlib.Path(sys.argv[1])
count=int(sys.argv[2])
ratio=float(sys.argv[3])
deadline=float(sys.argv[4])
workers=int(sys.argv[5])
min_queue=int(sys.argv[6])
min_success=int(sys.argv[7])
pressure_ready=int(sys.argv[8])
peer_ok=int(sys.argv[9])
producer_clean=int(sys.argv[10])
drained=int(sys.argv[11])
progress_before=int(sys.argv[12])
progress_after=int(sys.argv[13])
baselines=[json.load(open(root/f"b_baseline_{i}.json", encoding="utf-8")) for i in (1,2,3)]
with_a=json.load(open(root/"b_with_a.json", encoding="utf-8"))
recovery=json.load(open(root/"b_recovery.json", encoding="utf-8"))
metrics=[json.loads(line) for line in open(root/"metrics_with_a.jsonl", encoding="utf-8") if line.strip()]
median=statistics.median(x["elapsed_seconds"] for x in baselines)
baseline_ok=all(x["successes"] == count and x["deadline_met"] and x["http_5xx"] == 0 for x in baselines)
degraded=(not with_a["deadline_met"]) and (with_a["successes"] < count or with_a["elapsed_seconds"] >= median*ratio)
valid=[m for m in metrics if "error" not in m]
active_samples=sum(1 for m in valid if m.get("active", 0) >= 1)
queue_samples=sum(1 for m in valid if m.get("queue_depth", 0) >= min_queue)
max_active_seen=max((m.get("max_active", 0) for m in valid), default=0)
pressure_ok=len(valid) >= 12 and active_samples >= len(valid)*0.7 and queue_samples >= len(valid)*0.6 and max_active_seen >= workers
a_counters=[m.get("a_completed", 0) for m in valid]
b_counters=[m.get("b_completed", 0) for m in valid]
completion_series_ok=len(a_counters) >= 2 and max(a_counters) > min(a_counters) and max(b_counters) >= min(b_counters)
a_progress_ok=progress_after-progress_before >= min_success
no_server_errors=with_a["http_5xx"] == 0 and all(m.get("http_5xx", 1) == 0 for m in valid)
recovery_limit=max(deadline, median*1.5)
recovery_ok=drained and recovery["successes"] == count and recovery["deadline_met"] and recovery["elapsed_seconds"] <= recovery_limit and recovery["http_5xx"] == 0
summary={
    "baseline_elapsed_seconds": [x["elapsed_seconds"] for x in baselines],
    "baseline_median_seconds": median,
    "with_a_elapsed_seconds": with_a["elapsed_seconds"],
    "with_a_successes": with_a["successes"],
    "recovery_elapsed_seconds": recovery["elapsed_seconds"],
    "metrics_samples": len(valid),
    "active_full_samples": active_samples,
    "max_active_seen": max_active_seen,
    "queue_pressure_samples": queue_samples,
    "a_progress_delta": progress_after-progress_before,
    "a_completed_range": [min(a_counters or [0]), max(a_counters or [0])],
    "b_completed_range": [min(b_counters or [0]), max(b_counters or [0])],
    "checks": {"baseline": baseline_ok, "degraded": degraded, "pressure_ready": bool(pressure_ready), "pressure_series": pressure_ok, "completion_series": completion_series_ok, "a_progress": a_progress_ok, "peer": bool(peer_ok), "producer_clean_stop": bool(producer_clean), "no_server_errors": no_server_errors, "drained": bool(drained), "recovery": recovery_ok},
    "causal_exclusions": {"upstream": "loopback service only", "cpu": "request service time is bounded wall-clock validation delay and process CPU is archived", "application_lock": "no application data lock is used in request processing", "server_error": "HTTP 5xx count must remain zero"},
}
with open(root/"oracle_summary.json", "w", encoding="utf-8") as handle:
    json.dump(summary, handle, indent=2, sort_keys=True)
checks=summary["checks"]
ok=all(checks.values())
if ok:
    print("CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 A_IDENTITY_RETAINED=1 A_PROGRESS_CONTINUES=1 PRESSURE_SERIES_OK=1 RECOVERY_OK=1 NO_SERVER_ERRORS=1 RESOURCE=http_worker_pool REASON=high_rate_short_request_churn baseline_median=%.4f with_a=%.4f with_a_successes=%d recovery=%.4f" % (median, with_a["elapsed_seconds"], with_a["successes"], recovery["elapsed_seconds"]))
else:
    print("CONFLICT_OK=0 A_HEALTHY=%d B_ALONE_OK=%d B_WITH_A_BLOCKED=%d A_IDENTITY_RETAINED=%d A_PROGRESS_CONTINUES=%d PRESSURE_SERIES_OK=%d RECOVERY_OK=%d NO_SERVER_ERRORS=%d RESOURCE=http_worker_pool details=%s" % (pressure_ready, baseline_ok, degraded, peer_ok, a_progress_ok, pressure_ok and completion_series_ok, recovery_ok, no_server_errors, json.dumps(checks, sort_keys=True)))
    raise SystemExit(1)
PY

stop_server_only
trap - EXIT
