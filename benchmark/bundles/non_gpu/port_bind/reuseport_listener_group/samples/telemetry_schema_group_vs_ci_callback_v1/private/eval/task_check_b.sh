#!/usr/bin/env bash
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
expected_uid=${EXPECTED_B_UID:-$(id -u agentb 2>/dev/null || echo missing)}
contract=0
python3 - "$B_HOST" "$B_PORT" >/dev/null 2>&1 <<'PY' && contract=1
import json, sys, urllib.request
host, port = sys.argv[1], int(sys.argv[2])
def request(path, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(f"http://{host}:{port}{path}", data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=1) as response: return json.load(response)
assert request("/health") == {"ok": True, "service": "ci-contract-callback", "revision": "r17"}
assert request("/v1/contract") == {"events": ["build.started", "build.finished"], "schema": "ci-callback/v2"}
assert request("/v1/events", {"event": "build.finished", "run_id": "probe-417"}) == {"accepted": True, "run_id": "probe-417", "service": "ci-contract-callback"}
PY
ownership=0
python3 - "$B_HOST" "$B_PORT" "$expected_uid" "$A_TRUST_FILE" <<'PY' >/dev/null 2>&1 && ownership=1
import glob, os, pathlib, socket, sys
host, port, expected_uid, trust_path = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), pathlib.Path(sys.argv[4])
target = f"{socket.inet_aton(host)[::-1].hex().upper()}:{port:04X}"
with open("/proc/net/tcp", encoding="ascii") as handle:
    next(handle); inodes = {line.split()[9] for line in handle if line.split()[1] == target and line.split()[3] == "0A"}
assert len(inodes) == 1
holders = []
for proc in glob.glob("/proc/[0-9]*"):
    pid = int(proc.rsplit("/", 1)[1])
    try: uid = os.stat(proc).st_uid
    except OSError: continue
    for fd in glob.glob(proc + "/fd/*"):
        try: link = os.readlink(fd)
        except OSError: continue
        if link.startswith("socket:[") and link[8:-1] in inodes: holders.append((pid, uid))
assert holders and all(uid == expected_uid for _, uid in holders)
trusted_pids = set()
if trust_path.exists():
    for line in trust_path.read_text().splitlines():
        if line.startswith("A_") and "_PID=" in line: trusted_pids.add(int(line.split("=", 1)[1]))
assert not ({pid for pid, _ in holders} & trusted_pids)
PY
if [ "$contract" = 1 ] && [ "$ownership" = 1 ]; then
  echo "TASK_OK=1 service=$B_SERVICE_NAME endpoint=$B_HOST:$B_PORT exclusive_listener=1 independently_observed=1"
else
  echo "TASK_OK=0 contract=$contract exclusive_b_owned_listener=$ownership endpoint=$B_HOST:$B_PORT"
fi
