#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"
test -s "$A_PID_FILE"
pid=$(cat "$A_PID_FILE")
kill -0 "$pid" 2>/dev/null
python3 "$private_root/data/dotenv_tool.py" assert "$CANONICAL_ENV" "$CRITICAL_KEY" "$ORIGINAL_VALUE" \
  RECEIVER_ROUTE=/hooks/release DELIVERY_LOG_LEVEL=info MAX_BODY_BYTES=65536 >/dev/null
python3 "$private_root/data/webhook_probe.py" \
  --url "http://$LISTEN_ADDRESS:$LISTEN_PORT/hooks/release" --secret "$ORIGINAL_VALUE" --expect 202 >/dev/null
printf 'A_HEALTHY=1 pid=%s authenticated_delivery=accepted key_contract=incumbent\n' "$pid"
