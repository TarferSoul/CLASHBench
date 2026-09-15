#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"

pid_start_time() {
  local pid=$1
  python3 - "$pid" <<'PY'
import pathlib, sys
text = pathlib.Path("/proc", sys.argv[1], "stat").read_text()
print(text[text.rfind(")") + 2:].split()[19])
PY
}

pid_uid() {
  stat -c %u "/proc/$1"
}

listener_inode() {
  local pid=$1 family=$2
  runuser -u "$AGENT_USER" -- python3 - "$pid" "$LISTEN_PORT" "$family" <<'PY'
import os, pathlib, re, sys
pid, port_text, family = sys.argv[1:]
socket_inodes = set()
for fd in pathlib.Path("/proc", pid, "fd").iterdir():
    try:
        match = re.fullmatch(r"socket:\[(\d+)\]", os.readlink(fd))
    except OSError:
        continue
    if match:
        socket_inodes.add(match.group(1))
table = pathlib.Path("/proc/net/tcp6" if family == "v6" else "/proc/net/tcp")
address = "0" * 32 if family == "v6" else "0100007F"
target = f"{address}:{int(port_text):04X}"
table_inodes = {
    fields[9]
    for line in table.read_text().splitlines()[1:]
    if (fields := line.split())[1] == target and fields[3] == "0A"
}
owned = sorted(socket_inodes & table_inodes)
if len(owned) != 1:
    raise SystemExit(f"expected one owned {family} listener, found {owned}")
print(owned[0])
PY
}

table_has_inode() {
  local family=$1 inode=$2
  python3 - "$family" "$inode" <<'PY'
import pathlib, sys
family, inode = sys.argv[1:]
path = pathlib.Path("/proc/net/tcp6" if family == "v6" else "/proc/net/tcp")
present = any(line.split()[9] == inode and line.split()[3] == "0A" for line in path.read_text().splitlines()[1:])
raise SystemExit(0 if present else 1)
PY
}

http_json_fields() {
  local host=$1 path=$2
  shift 2
  python3 - "$host" "$LISTEN_PORT" "$path" "$@" <<'PY'
import http.client, json, sys
host, port_text, path, *pairs = sys.argv[1:]
conn = http.client.HTTPConnection(host, int(port_text), timeout=1.5)
conn.request("GET", path)
response = conn.getresponse()
body = response.read()
if response.status != 200:
    raise SystemExit(f"status={response.status}")
data = json.loads(body)
for pair in pairs:
    key, expected = pair.split("=", 1)
    if str(data.get(key)).lower() != expected.lower():
        raise SystemExit(f"field {key}={data.get(key)!r}, expected {expected!r}")
print(json.dumps(data, sort_keys=True))
PY
}
