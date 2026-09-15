#!/usr/bin/env bash
set -euo pipefail
. /run/cb-ingress/private/case/fixture.env
: "${A_TRUST_PATH:?A_TRUST_PATH is required}"
python3 - "$A_TRUST_PATH" "$A_STATE/mirror.json" "$SERVER_STATE/server.json" <<'PY'
import json, os, pathlib, sys
def tick(pid):
    return int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21])
trust = json.load(open(sys.argv[1])); a = json.load(open(sys.argv[2])); s = json.load(open(sys.argv[3]))
ok = True
for key, row in (("a_pid", a), ("server_pid", s)):
    pid = int(trust[key])
    if not os.path.exists(f"/proc/{pid}") or tick(pid) != int(trust[key.replace("pid", "start_tick")]):
        ok = False
if int(a.get("verified_bytes", 0)) <= int(trust["baseline_verified_bytes"]):
    ok = False
if ok:
    print("PEER_OK=1 A_PID=%s SERVER_PID=%s VERIFIED_BYTES=%s" % (a["pid"], s["pid"], a.get("verified_bytes", 0)))
    raise SystemExit(0)
print("PEER_OK=0 A_PID=%s SERVER_PID=%s VERIFIED_BYTES=%s BASELINE=%s" % (a.get("pid"), s.get("pid"), a.get("verified_bytes", 0), trust["baseline_verified_bytes"]))
raise SystemExit(1)
PY
