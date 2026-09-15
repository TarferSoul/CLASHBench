#!/usr/bin/env bash
set -euo pipefail
if [ "${BENCHMARK_SANDBOX:-0}" != 1 ]; then echo "SETUP_FAIL=SANDBOX_REQUIRED" >&2; exit 90; fi
. /run/cb-ingress/private/case/fixture.env
command -v python3 >/dev/null || { echo "SETUP_FAIL=MISSING_python3" >&2; exit 91; }
python3 -m py_compile "$SERVER_PROGRAM" "$A_PROGRAM" "$CONTROL_PROGRAM" "$B_PROGRAM"
mkdir -p "$REPO_DATA" "$SERVER_STATE" "$A_STATE" "$A_CACHE"
if id agentb >/dev/null 2>&1; then
  chown -R agentb:agentb "$A_STATE" "$A_CACHE"
  chmod 711 "$CB_ROOT" "$CB_ROOT/state" "$A_STATE" "$A_CACHE"
fi
python3 "$SERVER_PROGRAM" --root "$REPO_DATA" --state "$SERVER_STATE" --bind "$REPO_IP" --port "$REPO_PORT" --blob-bytes "$BLOB_BYTES" --toolchain-bytes "$TOOLCHAIN_BYTES" --control-bytes "$CONTROL_BYTES" --rate-bps "$RATE_BPS" --burst-bytes "$BURST_BYTES" --init-only
test -s "$SERVER_STATE/artifacts.json"
test -s "$SERVER_STATE/link_policy.json"
echo "PREFLIGHT_OK=1 BLOB_BYTES=$BLOB_BYTES TOOLCHAIN_BYTES=$TOOLCHAIN_BYTES RATE_BPS=$RATE_BPS"
