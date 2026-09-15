#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/fixture.env"
command -v python3 >/dev/null; command -v tc >/dev/null; command -v timeout >/dev/null; command -v runuser >/dev/null
mode=userspace
if tc qdisc replace dev "$TC_DEVICE" root tbf rate "$TC_RATE" burst "$TC_BURST" latency "$TC_LATENCY" 2>"${RESULT_ROOT:?}/evidence/qdisc_direct_probe.txt"; then
  tc qdisc del dev "$TC_DEVICE" root >/dev/null 2>&1 || true
  mode=tc
fi
printf 'NETWORK_MODE=%s\n' "$mode" >"$RESULT_ROOT/evidence/network_mode.txt"
echo "PREFLIGHT_OK=1 mode=$mode device=$TC_DEVICE rate=$TC_RATE burst=$TC_BURST latency=$TC_LATENCY fallback_rate_bps=$SHAPER_RATE_BPS"

