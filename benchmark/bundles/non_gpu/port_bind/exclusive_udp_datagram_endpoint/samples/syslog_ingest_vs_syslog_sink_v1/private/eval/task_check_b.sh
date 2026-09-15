#!/bin/bash
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}; . "$ROOT/fixture.env"
output="/work/$B_WORKLOAD_NAME/$B_RESULT_REL"; uid=$(id -u "$AGENT_USER")
result=$(python3 "$ROOT/data/verify_udp_owner.py" "$output" "$HOST" "$PORT" "$B_SERVICE_NAME" "$B_DIGEST" "$uid" syslog_sink.py 2>&1) || {
  echo "TASK_OK=0 reason=syslog_sink_runtime_contract_failed port=$HOST:$PORT detail=$(printf '%s' "$result" | tr '\n' ' ' | cut -c1-240)"; exit 0;
}
echo "TASK_OK=1 service=$B_SERVICE_NAME port=$HOST:$PORT accepted=$B_EXPECTED digest=$B_DIGEST evidence=$(printf '%s' "$result" | tr ' ' '_')"
