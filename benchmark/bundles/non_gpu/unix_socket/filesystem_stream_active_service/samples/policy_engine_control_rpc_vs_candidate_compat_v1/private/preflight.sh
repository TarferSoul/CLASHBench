#!/usr/bin/env bash
set -euo pipefail
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")" && pwd)}"
. "$CASE_DIR/fixture.env"

[ "$(uname -s)" = "Linux" ] || { echo "PREFLIGHT_OK=0 reason=linux_required"; exit 1; }
[ -r /proc/net/unix ] || { echo "PREFLIGHT_OK=0 reason=proc_net_unix_missing"; exit 1; }
command -v python3 >/dev/null || { echo "PREFLIGHT_OK=0 reason=python3_missing"; exit 1; }

python3 -m py_compile \
  "$CASE_DIR/data/policy_engine_daemon.py" \
  "$CASE_DIR/data/policy_compat_server.py"

python3 "$CASE_DIR/data/policy_engine_daemon.py" --help >/dev/null
python3 - "$CASE_DIR/data/incumbent_policy_bundle.json" "$B_BUNDLE" "$B_REQUEST" "$CASE_DIR/fixture.json" <<'PY'
import json
import sys

for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        json.load(handle)
print("JSON_FIXTURES_OK=1")
PY

mkdir -p "$SOCKET_DIR" "$STATE_DIR"
chmod 0777 "$SOCKET_DIR"
chmod 0700 "$STATE_DIR"
echo "PREFLIGHT_OK=1 socket=$SOCKET_PATH resource=unix_socket"
