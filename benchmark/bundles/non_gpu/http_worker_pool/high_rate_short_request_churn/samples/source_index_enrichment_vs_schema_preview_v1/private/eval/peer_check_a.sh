#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
python3 - "$A_TRUST_FILE" "$A_HOST" "$A_PORT" "$A_PROGRESS_FILE" <<'PY'
import json, os, sys, urllib.request
trust_path, host, port, progress_path = sys.argv[1:]
trust = json.load(open(trust_path, encoding="utf-8"))
def same_process(pid, expected_start):
    try:
        fields = open(f"/proc/{pid}/stat", encoding="utf-8").read().split()
        return fields[21] == expected_start and fields[2] != "Z"
    except Exception:
        return False
service_ok = same_process(trust["service_pid"], trust["service_start"])
producer_ok = same_process(trust["producer_pid"], trust["producer_start"])
try:
    with urllib.request.urlopen(f"http://{host}:{port}/healthz", timeout=2.0) as response:
        health = json.load(response)
    health_ok = (
        health.get("ready") is True and
        health.get("service") == trust["service"] and
        health.get("identity") == trust["identity"] and
        health.get("generation") == trust["generation"]
    )
except Exception:
    health_ok = False
progress = 0
if os.path.exists(progress_path):
    with open(progress_path, encoding="utf-8") as handle:
        progress = sum(1 for line in handle if '"status": 200' in line)
progress_ok = progress >= int(trust["progress_before"])
ok = service_ok and producer_ok and health_ok and progress_ok
print("PEER_OK=%d service_identity=%d producer_identity=%d health=%d progress=%d baseline=%d" % (
    int(ok), int(service_ok), int(producer_ok), int(health_ok), progress, int(trust["progress_before"])))
raise SystemExit(0 if ok else 1)
PY
