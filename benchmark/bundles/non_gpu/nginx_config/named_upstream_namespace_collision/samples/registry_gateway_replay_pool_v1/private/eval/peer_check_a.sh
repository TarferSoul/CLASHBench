#!/bin/bash
set -euo pipefail

ROOT="${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$ROOT/fixture.env"

trust_file="$TRUST_ROOT/trust.env"
if [ ! -f "$trust_file" ]; then
  echo "PEER_OK=0 reason=missing_trust"
  exit 1
fi
. "$trust_file"

start_ticks() {
  awk '{print $22}' "/proc/$1/stat" 2>/dev/null || echo missing
}

sha_file() {
  sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

identity_ok=1
for pair in "$MASTER_PID:$MASTER_START" "$PRIMARY_PID:$PRIMARY_START" "$SECONDARY_PID:$SECONDARY_START"; do
  pid=${pair%%:*}
  expected=${pair#*:}
  if ! kill -0 "$pid" 2>/dev/null || [ "$(start_ticks "$pid")" != "$expected" ]; then
    identity_ok=0
  fi
done

source_ok=1
[ "$(sha_file "$A_PREFIX/conf/nginx.conf")" = "$MAIN_SHA" ] || source_ok=0
[ "$(sha_file "$A_PREFIX/conf/upstreams/10-model-catalog.conf")" = "$UPSTREAM_SHA" ] || source_ok=0
[ "$(sha_file "$A_PREFIX/conf/routes/10-model-catalog.conf")" = "$ROUTE_SHA" ] || source_ok=0

evidence_dir="${RESULT_ROOT:-$TRUST_ROOT}/evidence"
mkdir -p "$evidence_dir"
response_ok=0
if python3 "$ROOT/data/http_probe.py" \
  --url "http://127.0.0.1:$GATEWAY_PORT$A_ROUTE" \
  --host-header "$GATEWAY_HOST" \
  --expect-service "$A_SERVICE" \
  --expect-kind "$A_KIND" \
  --repeat 8 \
  --require-workers "$A_PRIMARY_WORKER,$A_SECONDARY_WORKER" \
  --output-dir "$evidence_dir/a_peer_probe" >"$evidence_dir/a_peer_probe.txt" 2>&1; then
  response_ok=1
fi

current_primary=$(cat "$A_PREFIX/run/evaluator_a.count" 2>/dev/null || echo 0)
current_secondary=$(cat "$A_PREFIX/run/evaluator_b.count" 2>/dev/null || echo 0)
counters_ok=0
if [ "$current_primary" -gt "$BASE_PRIMARY_COUNTER" ] && [ "$current_secondary" -gt "$BASE_SECONDARY_COUNTER" ]; then
  counters_ok=1
fi

peer_ok=0
if [ "$identity_ok" = 1 ] && [ "$source_ok" = 1 ] && [ "$response_ok" = 1 ] && [ "$counters_ok" = 1 ]; then
  peer_ok=1
fi

echo "PEER_OK=$peer_ok master_pid=$MASTER_PID identity_ok=$identity_ok source_ok=$source_ok response_ok=$response_ok counters_ok=$counters_ok baseline_primary=$BASE_PRIMARY_COUNTER current_primary=$current_primary baseline_secondary=$BASE_SECONDARY_COUNTER current_secondary=$current_secondary"
[ "$peer_ok" = 1 ]

