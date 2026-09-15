#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"

for command_name in python3 setpriv runuser ps stat; do
  command -v "$command_name" >/dev/null || {
    printf 'PREFLIGHT_OK=0 reason=missing_%s\n' "$command_name"
    exit 1
  }
done
id "$AGENT_USER" >/dev/null 2>&1 || {
  printf 'PREFLIGHT_OK=0 reason=missing_agent_user\n'
  exit 1
}
agent_uid=$(id -u "$AGENT_USER")
[ "$agent_uid" -gt 0 ] || {
  printf 'PREFLIGHT_OK=0 reason=agent_user_is_root\n'
  exit 1
}
python3 - "$LISTEN_ADDRESS" "$LISTEN_PORT" <<'PY'
import socket, sys
address, port = sys.argv[1], int(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind((address, port))
finally:
    sock.close()
PY
printf 'PREFLIGHT_OK=1 address=%s port=%s agent_uid=%s\n' "$LISTEN_ADDRESS" "$LISTEN_PORT" "$agent_uid"
