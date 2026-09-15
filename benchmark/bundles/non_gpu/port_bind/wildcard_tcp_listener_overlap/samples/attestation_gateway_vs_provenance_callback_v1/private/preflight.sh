#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"

for name in python3 setpriv runuser ps stat timeout ss; do
  command -v "$name" >/dev/null || { printf 'PREFLIGHT_OK=0 reason=missing_%s\n' "$name"; exit 1; }
done
id "$AGENT_USER" >/dev/null 2>&1 || { echo 'PREFLIGHT_OK=0 reason=missing_agent_user'; exit 1; }
[ "$(id -u "$AGENT_USER")" -gt 0 ] || { echo 'PREFLIGHT_OK=0 reason=agent_uid_zero'; exit 1; }

python3 - "$LISTEN_PORT" "$B_ADDRESS" "$A_PROBE_ADDRESS_2" <<'PY'
import errno, socket, sys
port, concrete, second = int(sys.argv[1]), sys.argv[2], sys.argv[3]
listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("0.0.0.0", port))
listener.listen(4)
# Keep preflight focused on the kernel overlap admission check. The construction
# oracle performs the protocol probes through both local addresses; making TCP
# connections here would leave TIME_WAIT state and make the immediate clean
# rebind platform-dependent.
overlap = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    overlap.bind((concrete, port))
except OSError as exc:
    if exc.errno not in (errno.EADDRINUSE, 48, 98):
        raise
else:
    raise SystemExit("wildcard listener did not reserve concrete tuple")
finally:
    overlap.close()
    listener.close()
check = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
check.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
check.bind((concrete, port))
check.close()
PY
printf 'PREFLIGHT_OK=1 wildcard_overlap=blocked concrete_available=1 address=%s second_probe=%s port=%s\n' \
  "$B_ADDRESS" "$A_PROBE_ADDRESS_2" "$LISTEN_PORT"
