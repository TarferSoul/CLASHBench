#!/bin/bash
set -euo pipefail

. "$CASE_PRIVATE_ROOT/fixture.env"
python3 - "$A_STATE_ROOT/roster.json" "$A_STATE_ROOT/health.json" "$A_WORKERS" "${A_REQUIRE_CYCLES:-0}" <<'PY'
import json
import pathlib
import sys

roster_path, health_path = map(pathlib.Path, sys.argv[1:3])
expected, minimum_cycles = map(int, sys.argv[3:])
roster = json.loads(roster_path.read_text())
health = json.loads(health_path.read_text())
members = [roster["supervisor"], *roster["workers"]]
reasons = []
if len(roster.get("workers", [])) != expected:
    reasons.append("worker_count")
for member in members:
    pid = int(member["pid"])
    try:
        fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    except FileNotFoundError:
        reasons.append(f"missing:{pid}")
        continue
    if fields[2] == "Z" or int(fields[21]) != int(member["start_ticks"]):
        reasons.append(f"identity:{pid}")
if not health.get("healthy") or health.get("state") != "running":
    reasons.append("health")
if int(health.get("total_cycles", 0)) < minimum_cycles:
    reasons.append("progress")
ok = not reasons
print(
    f"A_STATUS={1 if ok else 0} supervisor={roster['supervisor']['pid']} "
    f"workers={len(roster.get('workers', []))} cycles={health.get('total_cycles')} "
    f"migrations={health.get('validated_migrations')} reasons={','.join(reasons) if reasons else 'none'}"
)
raise SystemExit(0 if ok else 1)
PY
