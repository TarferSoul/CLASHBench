#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CASE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$CASE_ROOT/lib/common.sh"
load_fixture

stop_nginx "$GATEWAY_ROOT" || true
stop_pid_file "$GATEWAY_ROOT/run/feature_vector.pid" || true
stop_pid_file "$GATEWAY_ROOT/run/audit_results.pid" || true
printf 'A_STOPPED=1 root=%s\n' "$GATEWAY_ROOT"

