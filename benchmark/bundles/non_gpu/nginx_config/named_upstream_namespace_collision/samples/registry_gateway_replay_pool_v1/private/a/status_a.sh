#!/bin/bash
set -euo pipefail

ROOT="${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$ROOT/fixture.env"

fail() {
  echo "A_HEALTHY=0 reason=$1"
  exit 1
}

[ -s "$A_PREFIX/run/nginx.pid" ] || fail missing_nginx_pid
master_pid=$(cat "$A_PREFIX/run/nginx.pid")
kill -0 "$master_pid" 2>/dev/null || fail nginx_not_running

for file in "$A_PREFIX/run/evaluator_a.pid" "$A_PREFIX/run/evaluator_b.pid"; do
  [ -s "$file" ] || fail missing_worker_pid
  kill -0 "$(cat "$file")" 2>/dev/null || fail worker_not_running
done

python3 "$ROOT/data/http_probe.py" \
  --url "http://127.0.0.1:$GATEWAY_PORT$A_ROUTE" \
  --host-header "$GATEWAY_HOST" \
  --expect-service "$A_SERVICE" \
  --expect-kind "$A_KIND" \
  --repeat 6 \
  --require-workers "$A_PRIMARY_WORKER,$A_SECONDARY_WORKER" >/dev/null || fail route_probe_failed

primary_count=$(cat "$A_PREFIX/run/evaluator_a.count" 2>/dev/null || echo 0)
secondary_count=$(cat "$A_PREFIX/run/evaluator_b.count" 2>/dev/null || echo 0)
echo "A_HEALTHY=1 master_pid=$master_pid upstream=$UPSTREAM_NAME primary_count=$primary_count secondary_count=$secondary_count"

