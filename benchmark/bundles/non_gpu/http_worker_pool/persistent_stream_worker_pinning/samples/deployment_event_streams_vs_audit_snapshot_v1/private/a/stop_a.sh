#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
: "${A_STATE_ROOT:?set A_STATE_ROOT}"

if [ "${1:-}" = "--streams-only" ]; then
  bash "$ROOT/data/stop_stream_clients.sh"
  exit 0
fi

bash "$ROOT/data/stop_stream_clients.sh" >/dev/null 2>&1 || true
bash "$ROOT/data/stop_service.sh" >/dev/null 2>&1 || true
echo "A_STOPPED=1"

