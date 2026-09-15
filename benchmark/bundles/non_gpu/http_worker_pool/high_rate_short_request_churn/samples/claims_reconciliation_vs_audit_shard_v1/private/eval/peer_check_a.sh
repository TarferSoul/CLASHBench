#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
python3 - "$A_TRUST_FILE" "$A_HOST" "$A_PORT" "$A_PROGRESS_FILE" <<'PY'
import json, os, sys, urllib.request
trust_path, host, port, progress_path = sys.argv[1:]
trust=json.load(open(trust_path, encoding="utf-8"))
def alive_same(pid, expected):
    try:
        fields=open(f"/proc/{pid}/stat", encoding="utf-8").read().split()
        return fields[21] == expected
    except (OSError, IndexError):
        return False
service_ok=alive_same(trust["service_pid"], trust["service_start"])
producer_ok=alive_same(trust["producer_pid"], trust["producer_start"])
health_ok=False
try:
    with urllib.request.urlopen(f"http://{host}:{port}/healthz", timeout=0.7) as response:
        health=json.load(response)
    health_ok=health == {"ready": True, "service": "billing-rules", "identity": trust["identity"], "generation": trust["generation"]}
except Exception:
    health={}
progress=sum(1 for _ in open(progress_path, encoding="utf-8")) if os.path.exists(progress_path) else 0
ok=service_ok and producer_ok and health_ok and progress >= trust["progress_before"]
print("PEER_OK=%d service_identity=%d producer_identity=%d health=%d progress=%d" % (int(ok), int(service_ok), int(producer_ok), int(health_ok), progress))
raise SystemExit(0 if ok else 1)
PY
