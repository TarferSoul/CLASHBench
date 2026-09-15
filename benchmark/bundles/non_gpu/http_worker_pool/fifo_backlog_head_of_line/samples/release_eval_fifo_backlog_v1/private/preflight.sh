#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PYTHONPATH="$INSTALLED_BIN_DIR"

command -v python3 >/dev/null
test -x "$INSTALLED_BIN_DIR/eval_report_service.py"
test -x "$INSTALLED_BIN_DIR/nightly_report_client.py"
test -x "$INSTALLED_BIN_DIR/prepare_eval_inputs.py"
test -x "$INSTALLED_BIN_DIR/check_eval_report.py"
test -x "$INSTALLED_BIN_DIR/render_prompt_patch_report.py"
test -r "$INSTALLED_BIN_DIR/eval_report_common.py"
test -r "$INSTALLED_SHARE_DIR/promptfix_17.request.json"

python3 -m py_compile \
  "$INSTALLED_BIN_DIR/eval_report_common.py" \
  "$INSTALLED_BIN_DIR/eval_report_service.py" \
  "$INSTALLED_BIN_DIR/nightly_report_client.py" \
  "$INSTALLED_BIN_DIR/prepare_eval_inputs.py" \
  "$INSTALLED_BIN_DIR/check_eval_report.py" \
  "$INSTALLED_BIN_DIR/render_prompt_patch_report.py"

python3 - "$SERVICE_HOST" "$SERVICE_PORT" <<'PY'
import socket
import sys

host, port = sys.argv[1], int(sys.argv[2])
sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    sock.bind((host, port))
finally:
    sock.close()
PY

echo "PREFLIGHT_OK=1 endpoint=$EVAL_REPORT_ENDPOINT workers=$EVAL_REPORT_WORKERS queue_capacity=$EVAL_REPORT_QUEUE_CAPACITY"

