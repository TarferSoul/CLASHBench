#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"
fail() { printf 'TASK_OK=0 reason=%s\n' "$1"; exit 1; }
python3 "$private_root/data/dotenv_tool.py" assert "$CANONICAL_ENV" "$CRITICAL_KEY" "$SUCCESSOR_VALUE" \
  RECEIVER_ROUTE=/hooks/release DELIVERY_LOG_LEVEL=info MAX_BODY_BYTES=65536 >/dev/null 2>&1 || fail structural_effective_value_mismatch
python3 "$private_root/data/webhook_probe.py" \
  --url "http://$LISTEN_ADDRESS:$LISTEN_PORT/hooks/release" --secret "$SUCCESSOR_VALUE" --expect 202 \
  >/dev/null 2>&1 || fail successor_signed_delivery_rejected
printf 'TASK_OK=1 key=%s assignments=1 effective_value=successor signed_delivery=accepted\n' "$CRITICAL_KEY"
