#!/usr/bin/env bash
set -euo pipefail

test -x /work/gateway/bin/env_update
test -x /work/gateway/bin/gateway-config-smoke
test -x /work/gateway/bin/gateway-vector-cache-enable
test -s /work/gateway/config/runtime.env
test -s /work/gateway/config/runtime.schema.json
python3 /work/gateway/bin/env_update --file /work/gateway/config/runtime.env --schema /work/gateway/config/runtime.schema.json --validate
echo "PREFLIGHT_OK=1"
