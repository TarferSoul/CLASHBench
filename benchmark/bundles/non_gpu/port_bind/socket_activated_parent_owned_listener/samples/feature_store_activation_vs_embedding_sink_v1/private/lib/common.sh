#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
. "$private_root/fixture.env"

pid_start_time() {
  local text
  text=$(cat "/proc/$1/stat")
  printf '%s\n' "${text##*) }" | awk '{print $20}'
}

pid_uid() { stat -c %u "/proc/$1"; }

listener_inode() {
  python3 - "$LISTEN_PORT" <<'PY'
import pathlib, sys
port_text = sys.argv[1]
target = "0100007F:%04X" % int(port_text)
listen = {fields[9] for line in pathlib.Path("/proc/net/tcp").read_text().splitlines()[1:] if (fields := line.split())[1] == target and fields[3] == "0A"}
if len(listen) != 1:
    raise SystemExit("expected one kernel listener for the exact tuple")
print(next(iter(listen)))
PY
}

listener_has_inode() {
  python3 - "$1" "$2" "$LISTEN_PORT" <<'PY'
import os, pathlib, re, sys
pid, expected, port_text = sys.argv[1:]
target = "0100007F:%04X" % int(port_text)
listen = {
    fields[9]
    for line in pathlib.Path("/proc/net/tcp").read_text().splitlines()[1:]
    if (fields := line.split())[1] == target and fields[3] == "0A"
}
owned = set()
for fd in pathlib.Path("/proc", pid, "fd").iterdir():
    try:
        match = re.fullmatch(r"socket:\[(\d+)\]", os.readlink(fd))
    except OSError:
        continue
    if match:
        owned.add(match.group(1))
if expected not in listen:
    print(f"LISTENER_KERNEL_MISSING=1 pid={pid} expected={expected} listen={','.join(sorted(listen))}", file=sys.stderr)
    raise SystemExit(1)
if expected not in owned:
    print(f"LISTENER_FD_UNAVAILABLE=1 pid={pid} expected={expected} listen={','.join(sorted(listen))}", file=sys.stderr)
raise SystemExit(0)
PY
}

http_json() { python3 - "$LISTEN_ADDRESS" "$LISTEN_PORT" "$1" <<'PY'
import json, sys, urllib.request
host, port, path = sys.argv[1:]
with urllib.request.urlopen(f"http://{host}:{port}{path}", timeout=1) as response:
    print(json.dumps(json.load(response), sort_keys=True))
PY
}
