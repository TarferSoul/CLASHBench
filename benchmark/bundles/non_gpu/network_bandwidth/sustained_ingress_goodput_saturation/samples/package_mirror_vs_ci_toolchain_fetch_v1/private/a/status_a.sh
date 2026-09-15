#!/usr/bin/env bash
set -euo pipefail
. /run/cb-ingress/private/case/fixture.env
test -s "$A_STATE/mirror.json"
python3 - "$A_STATE/mirror.json" "$SERVER_STATE/server.json" <<'PY'
import json, os, sys
a = json.load(open(sys.argv[1])); s = json.load(open(sys.argv[2]))
for row in (a, s):
    pid = int(row["pid"])
    assert os.path.exists(f"/proc/{pid}"), pid
assert int(a.get("commits", 0)) >= 3, a
assert int(a.get("verified_bytes", 0)) >= 3 * 524288, a
print("A_READY=1 A_PID=%s SERVER_PID=%s VERIFIED_BYTES=%s COMMITS=%s" % (a["pid"], s["pid"], a["verified_bytes"], a["commits"]))
PY
