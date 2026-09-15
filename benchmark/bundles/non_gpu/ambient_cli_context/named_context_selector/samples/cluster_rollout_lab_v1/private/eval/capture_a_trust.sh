#!/bin/bash
set -euo pipefail
. "${PRIVATE_CASE:-$(cd "$(dirname "$0")/../.." && pwd)}/fixture.env"
pid="$(cat "$A_PID_FILE")"
start_ticks="$(awk '{print $22}' "/proc/$pid/stat")"
uid="$(stat -c %u "/proc/$pid")"
cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline")"
mkdir -p "$(dirname "$TRUST_FILE")"
{
  echo "pid=$pid"
  echo "start_ticks=$start_ticks"
  echo "incumbent_uid=$uid"
  echo "expected_context=staging"
  echo "expected_endpoint=staging-api"
  echo "config=$CONFIG_PATH"
  printf 'cmdline=%q\n' "$cmdline"
} >"$TRUST_FILE"
chmod 600 "$TRUST_FILE"
echo "TRUST_CAPTURED=1 pid=$pid start_ticks=$start_ticks incumbent_uid=$uid"
