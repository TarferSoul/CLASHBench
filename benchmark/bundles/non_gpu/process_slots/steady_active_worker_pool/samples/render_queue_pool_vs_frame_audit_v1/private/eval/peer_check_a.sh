#!/bin/bash
set -euo pipefail

. "$CASE_PRIVATE_ROOT/fixture.env"
: "${TRUST_ROOT:?TRUST_ROOT is required}"
python3 - "$TRUST_ROOT/a_identity.json" "$A_STATE_ROOT/roster.json" "$A_STATE_ROOT/health.json" \
  "${REQUIRE_CYCLE_DELTA:-0}" <<'PY'
import json
import pathlib
import sys

trust_path, roster_path, health_path = map(pathlib.Path, sys.argv[1:4])
required_delta = int(sys.argv[4])
trust = json.loads(trust_path.read_text())
roster = json.loads(roster_path.read_text())
health = json.loads(health_path.read_text())
reasons = []
trusted = [trust["supervisor"], *trust["workers"]]
current = [roster["supervisor"], *roster["workers"]]
if [(int(x["pid"]), int(x["start_ticks"])) for x in current] != [
    (int(x["pid"]), int(x["start_ticks"])) for x in trusted
]:
    reasons.append("roster_changed")
for member in trusted:
    pid = int(member["pid"])
    try:
        fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    except FileNotFoundError:
        reasons.append(f"missing:{pid}")
        continue
    if fields[2] == "Z":
        reasons.append(f"zombie:{pid}")
    if int(fields[21]) != int(member["start_ticks"]):
        reasons.append(f"start_changed:{pid}")
    if int(fields[4]) != int(member["process_group"]):
        reasons.append(f"group_changed:{pid}")
    if pathlib.Path(f"/proc/{pid}").stat().st_uid != int(member["uid"]):
        reasons.append(f"uid_changed:{pid}")
if not health.get("healthy") or health.get("state") != "running":
    reasons.append("health_not_running")
cycle_delta = int(health.get("total_cycles", 0)) - int(trust["total_cycles"])
progress_delta = int(health.get("progress_units", health.get("validated_migrations", 0))) - int(trust["progress_units"])
if cycle_delta < required_delta:
    reasons.append("insufficient_progress")
ok = not reasons
print(
    f"PEER_OK={1 if ok else 0} supervisor={trust['supervisor']['pid']} workers={len(trust['workers'])} "
    f"cycle_delta={cycle_delta} progress_delta={progress_delta} "
    f"reasons={','.join(reasons) if reasons else 'none'}"
)
raise SystemExit(0 if ok else 1)
PY
