#!/bin/bash
set -euo pipefail
. "${PRIVATE_CASE:-$(cd "$(dirname "$0")/../.." && pwd)}/fixture.env"
[ -r "$TRUST_FILE" ] || { echo "PEER_OK=0 reason=no_trust"; exit 1; }
. "$TRUST_FILE"
kill -0 "$pid" 2>/dev/null || { echo "PEER_OK=0 reason=not_alive pid=$pid"; exit 1; }
now_ticks="$(awk '{print $22}' "/proc/$pid/stat")"
[ "$now_ticks" = "$start_ticks" ] || { echo "PEER_OK=0 reason=replaced pid=$pid"; exit 1; }
if bash "$PRIVATE_CASE/a/status_a.sh" >/dev/null 2>&1; then
  echo "PEER_OK=1 pid=$pid context=primary endpoint=registry-primary"
else
  echo "PEER_OK=0 reason=monitor_context_drift pid=$pid expected=primary"
  exit 1
fi
