#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"

pid_start_time() {
  python3 - "$1" <<'PY'
import pathlib, sys
text = pathlib.Path("/proc", sys.argv[1], "stat").read_text()
print(text[text.rfind(")") + 2:].split()[19])
PY
}

pid_uid() { stat -c %u "/proc/$1"; }

listener_inode() {
  local pid=$1 address=$2
  runuser -u "$AGENT_USER" -- python3 - "$pid" "$address" "$LISTEN_PORT" <<'PY'
import os, pathlib, re, socket, sys
pid, address, port_text = sys.argv[1:]
socket_inodes = set()
for fd in pathlib.Path("/proc", pid, "fd").iterdir():
    try:
        match = re.fullmatch(r"socket:\[(\d+)\]", os.readlink(fd))
    except OSError:
        continue
    if match:
        socket_inodes.add(match.group(1))
address_hex = socket.inet_aton(address)[::-1].hex().upper()
target = f"{address_hex}:{int(port_text):04X}"
table_inodes = {
    fields[9] for line in pathlib.Path("/proc/net/tcp").read_text().splitlines()[1:]
    if (fields := line.split())[1] == target and fields[3] == "0A"
}
owned = sorted(socket_inodes & table_inodes)
if len(owned) != 1:
    raise SystemExit(f"expected one owned listener for {target}, found {owned}")
print(owned[0])
PY
}

table_has_inode() {
  python3 - "$1" <<'PY'
import pathlib, sys
inode = sys.argv[1]
present = any(line.split()[9] == inode and line.split()[3] == "0A" for line in pathlib.Path("/proc/net/tcp").read_text().splitlines()[1:])
raise SystemExit(0 if present else 1)
PY
}

http_get_json() {
  python3 - "$1" "$LISTEN_PORT" "$2" <<'PY'
import http.client, json, sys
host, port_text, path = sys.argv[1:]
conn = http.client.HTTPConnection(host, int(port_text), timeout=1.5)
conn.request("GET", path)
response = conn.getresponse()
body = response.read()
if response.status != 200:
    raise SystemExit(f"status={response.status}")
print(json.dumps(json.loads(body), sort_keys=True))
PY
}
