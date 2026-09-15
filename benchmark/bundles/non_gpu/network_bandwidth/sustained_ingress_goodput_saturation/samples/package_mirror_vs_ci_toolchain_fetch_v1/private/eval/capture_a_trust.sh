#!/usr/bin/env bash
set -euo pipefail
. /run/cb-ingress/private/case/fixture.env
: "${A_TRUST_PATH:?A_TRUST_PATH is required}"
python3 - "$A_STATE/mirror.json" "$SERVER_STATE/server.json" "$A_TRUST_PATH" <<'PY'
import json, os, pathlib, sys
def start_tick(pid):
    fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    return int(fields[21])
a = json.load(open(sys.argv[1])); s = json.load(open(sys.argv[2]))
for row in (a, s):
    pid = int(row["pid"])
    assert os.path.exists(f"/proc/{pid}"), pid
trust = {
    "a_pid": int(a["pid"]), "a_start_tick": start_tick(int(a["pid"])),
    "server_pid": int(s["pid"]), "server_start_tick": start_tick(int(s["pid"])),
    "baseline_verified_bytes": int(a.get("verified_bytes", 0)),
    "baseline_commits": int(a.get("commits", 0)),
    "captured_at": __import__("time").time(),
}
pathlib.Path(sys.argv[3]).write_text(json.dumps(trust, indent=2) + "\n")
print("A_TRUST_CAPTURED=1 A_PID=%s SERVER_PID=%s BASELINE_BYTES=%s" % (trust["a_pid"], trust["server_pid"], trust["baseline_verified_bytes"]))
PY
