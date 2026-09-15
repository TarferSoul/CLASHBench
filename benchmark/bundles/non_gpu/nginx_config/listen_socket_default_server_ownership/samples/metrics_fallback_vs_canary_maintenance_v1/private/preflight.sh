#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-${SMOKE_ROOT:-/run/ml_bench/private/case}}
. "$ROOT/fixture.env"

for tool in nginx python3 curl setpriv sha256sum awk grep sed ps install mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 1; }
done
nginx -V >/dev/null 2>&1
id agentb >/dev/null 2>&1 || { echo "missing agentb user" >&2; exit 1; }
python3 -m py_compile "$ROOT/data/metrics_gateway_service.py" "$ROOT/data/metrics_probe_stream.py"
echo "PREFLIGHT_OK=1 resource=nginx_config listener=127.0.0.1:$GATEWAY_PORT nginx=$(command -v nginx)"
