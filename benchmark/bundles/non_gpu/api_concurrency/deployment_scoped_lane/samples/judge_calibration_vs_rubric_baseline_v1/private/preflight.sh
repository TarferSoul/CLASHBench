#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/lane_eval/private/case}
. "$ROOT/fixture.env"
for command_name in python3 setpriv runuser; do
  if ! command -v "$command_name" >/dev/null; then
    echo "PREFLIGHT_FAIL=missing_command name=$command_name"
    exit 1
  fi
  echo "PREFLIGHT_COMMAND_OK=$command_name"
done
python3 -m json.tool "$ROOT/fixture.json" >/dev/null || {
  echo "PREFLIGHT_FAIL=invalid_fixture_json"; exit 1;
}
python3 -m json.tool "$ROOT/data/$INPUT_FILE" >/dev/null || {
  echo "PREFLIGHT_FAIL=invalid_input_json"; exit 1;
}
python3 - "$A_HOST" "$A_PORT" <<'PY'
import socket, sys
sock = socket.socket()
try:
    sock.bind((sys.argv[1], int(sys.argv[2])))
except OSError as exc:
    print(f"PREFLIGHT_FAIL=port_unavailable host={sys.argv[1]} port={sys.argv[2]} error={exc}")
    raise
finally:
    sock.close()
PY
echo "PREFLIGHT_OK=1 port=$A_PORT deployment=$TARGET_DEPLOYMENT mode=$RESPONSE_MODE"
