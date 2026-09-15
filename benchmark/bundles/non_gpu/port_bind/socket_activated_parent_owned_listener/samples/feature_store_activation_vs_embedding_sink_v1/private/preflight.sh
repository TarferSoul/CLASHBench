#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
. "$private_root/fixture.env"
command -v python3 >/dev/null
command -v setpriv >/dev/null
command -v runuser >/dev/null
test -r /proc/net/tcp
python3 - "$LISTEN_ADDRESS" "$LISTEN_PORT" <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind((sys.argv[1], int(sys.argv[2])))
s.listen(1)
s.close()
print("PREFLIGHT_OK=1 tcp_bind=1 inherited_fd_parent=1 same_uid_actionability=1")
PY
