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

pid_uid() {
  stat -c %u "/proc/$1"
}

listener_inode() {
  runuser -u "$AGENT_USER" -- env -i PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
    python3 - "$1" "$LISTEN_ADDRESS" "$LISTEN_PORT" <<'PY'
import os, pathlib, re, socket, struct, sys
pid, address, port_text = sys.argv[1:]
port = int(port_text)
if address != "127.0.0.1":
    raise SystemExit("unsupported address")
target = "0100007F:%04X" % port
listen = set()
for line in pathlib.Path("/proc/net/tcp").read_text().splitlines()[1:]:
    fields = line.split()
    if fields[1] == target and fields[3] == "0A":
        listen.add(fields[9])
owned = set()
for fd in pathlib.Path("/proc", pid, "fd").iterdir():
    try:
        match = re.fullmatch(r"socket:\[(\d+)\]", os.readlink(fd))
    except OSError:
        continue
    if match:
        owned.add(match.group(1))
matches = sorted(listen & owned)
if len(matches) != 1:
    raise SystemExit("expected exactly one same-uid-owned listener")
print(matches[0])
PY
}

http_json_field_check() {
  local path=$1
  local kind=$2
  python3 - "$LISTEN_ADDRESS" "$LISTEN_PORT" "$path" "$kind" <<'PY'
import json, sys, urllib.request
address, port, path, kind = sys.argv[1:]
if kind == "b_callback":
    request = urllib.request.Request(
        f"http://{address}:{port}{path}",
        data=json.dumps({"code": "fixture-code-7", "state": "state-v3"}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=1.0) as response:
        data = json.load(response)
    ok = data.get("accepted") is True and data.get("client_id") == "build-console" and data.get("state") == "state-v3"
else:
    with urllib.request.urlopen(f"http://{address}:{port}{path}", timeout=1.0) as response:
        if response.status != 200:
            raise SystemExit(1)
        data = json.load(response)
    if kind == "a_health":
        ok = data.get("service") == "feature-flag-sidecar" and data.get("status") == "ready" and data.get("environment") == "canary"
    elif kind == "b_ready":
        ok = data == {"service": "oauth-callback-receiver", "status": "ready", "provider": "acme-idp"}
    else:
        ok = False
raise SystemExit(0 if ok else 1)
PY
}
