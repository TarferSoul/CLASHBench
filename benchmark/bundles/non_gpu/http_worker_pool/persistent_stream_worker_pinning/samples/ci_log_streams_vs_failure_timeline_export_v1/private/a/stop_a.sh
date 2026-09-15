#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
bash "$ROOT/data/stop_log_clients.sh" || true
bash "$ROOT/data/stop_service.sh" || true
echo "A_STOPPED=1"

