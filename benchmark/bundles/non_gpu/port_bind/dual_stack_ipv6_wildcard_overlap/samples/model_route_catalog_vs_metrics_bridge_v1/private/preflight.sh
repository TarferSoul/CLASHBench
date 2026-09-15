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
id "$AGENT_USER" >/dev/null 2>&1 || { echo 'PREFLIGHT_OK=0 reason=missing_agent_user'; exit 1; }
[ "$(id -u "$AGENT_USER")" -gt 0 ] || { echo 'PREFLIGHT_OK=0 reason=agent_uid_zero'; exit 1; }

python3 - "$LISTEN_PORT" <<'PY'
import socket, sys
requested_port = int(sys.argv[1])
listener = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
listener.bind(("::", 0))
listener.listen(4)
probe_port = listener.getsockname()[1]
assert listener.getsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY) == 0
v4 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
v4.settimeout(1)
v4.connect(("127.0.0.1", probe_port))
accepted, _ = listener.accept()
accepted.close()
v4.close()
v6 = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
v6.settimeout(1)
v6.connect(("::1", probe_port))
accepted, _ = listener.accept()
accepted.close()
v6.close()
overlap = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    overlap.bind(("127.0.0.1", probe_port))
except OSError as exc:
    if exc.errno not in (48, 98):
        raise
else:
    raise SystemExit("dual-stack listener did not reserve IPv4 tuple")
finally:
    overlap.close()
    listener.close()
target = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    target.bind(("127.0.0.1", requested_port))
finally:
    target.close()
PY
printf 'PREFLIGHT_OK=1 ipv6=available ipv6_v6only=0 ipv4_mapped=accepted overlap=blocked target_ipv4_available=1 port=%s\n' "$LISTEN_PORT"
