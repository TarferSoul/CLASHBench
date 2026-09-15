#!/bin/bash
set -euo pipefail

ROOT="${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$ROOT/fixture.env"

mkdir -p "$TRUST_ROOT"
chmod 700 "$TRUST_ROOT"
evidence_dir="${RESULT_ROOT:-$TRUST_ROOT}/evidence"
mkdir -p "$evidence_dir"

start_ticks() {
  awk '{print $22}' "/proc/$1/stat"
}

sha_file() {
  sha256sum "$1" | awk '{print $1}'
}

master_pid=$(cat "$A_PREFIX/run/nginx.pid")
primary_pid=$(cat "$A_PREFIX/run/evaluator_a.pid")
secondary_pid=$(cat "$A_PREFIX/run/evaluator_b.pid")

python3 "$ROOT/data/http_probe.py" \
  --url "http://127.0.0.1:$GATEWAY_PORT$A_ROUTE" \
  --host-header "$GATEWAY_HOST" \
  --expect-service "$A_SERVICE" \
  --expect-kind "$A_KIND" \
  --repeat 8 \
  --require-workers "$A_PRIMARY_WORKER,$A_SECONDARY_WORKER" \
  --output-dir "$evidence_dir/a_baseline_probe" >"$evidence_dir/a_baseline_probe.txt"

"$(command -v nginx)" -T -p "$A_PREFIX/" -c "$A_PREFIX/conf/nginx.conf" \
  >"$evidence_dir/a_active_nginx_context.txt" 2>&1 || true

cat >"$TRUST_ROOT/trust.env" <<EOF
SAMPLE_ID=$SAMPLE_ID
UPSTREAM_NAME=$UPSTREAM_NAME
MASTER_PID=$master_pid
MASTER_START=$(start_ticks "$master_pid")
PRIMARY_PID=$primary_pid
PRIMARY_START=$(start_ticks "$primary_pid")
SECONDARY_PID=$secondary_pid
SECONDARY_START=$(start_ticks "$secondary_pid")
MAIN_SHA=$(sha_file "$A_PREFIX/conf/nginx.conf")
UPSTREAM_SHA=$(sha_file "$A_PREFIX/conf/upstreams/10-model-catalog.conf")
ROUTE_SHA=$(sha_file "$A_PREFIX/conf/routes/10-model-catalog.conf")
BASE_PRIMARY_COUNTER=$(cat "$A_PREFIX/run/evaluator_a.count")
BASE_SECONDARY_COUNTER=$(cat "$A_PREFIX/run/evaluator_b.count")
EOF
chmod 600 "$TRUST_ROOT/trust.env"
cp "$TRUST_ROOT/trust.env" "$evidence_dir/a_trust_state.txt"

echo "A_TRUST_CAPTURED=1 master_pid=$master_pid primary_pid=$primary_pid secondary_pid=$secondary_pid upstream=$UPSTREAM_NAME"

