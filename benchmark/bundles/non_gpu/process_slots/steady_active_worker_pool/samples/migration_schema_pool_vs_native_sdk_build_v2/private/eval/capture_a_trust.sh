#!/bin/bash
set -euo pipefail

. "$CASE_PRIVATE_ROOT/fixture.env"
. "$CGROUP_ENV"
: "${TRUST_ROOT:?TRUST_ROOT is required}"
python3 - "$A_STATE_ROOT/roster.json" "$A_STATE_ROOT/health.json" "$TRUST_ROOT/a_identity.json" \
  "$A_WORKERS" "$SERVICE_UID" "$CGROUP_DIR" <<'PY'
import json
import pathlib
import sys

roster_path, health_path, output_path = map(pathlib.Path, sys.argv[1:4])
expected, expected_uid = map(int, sys.argv[4:6])
cgroup = pathlib.Path(sys.argv[6])
roster = json.loads(roster_path.read_text())
health = json.loads(health_path.read_text())
members = [roster["supervisor"], *roster["workers"]]
if len(roster.get("workers", [])) != expected:
    raise SystemExit("worker roster is incomplete")
captured = []
for member in members:
    pid = int(member["pid"])
    fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    item = dict(member)
    item.update({
        "pid": pid,
        "start_ticks": int(fields[21]),
        "process_group": int(fields[4]),
        "uid": pathlib.Path(f"/proc/{pid}").stat().st_uid,
    })
    if item["start_ticks"] != int(member["start_ticks"]) or item["uid"] != expected_uid:
        raise SystemExit(f"identity mismatch for {pid}")
    captured.append(item)
trust = {
    "supervisor": captured[0],
    "workers": captured[1:],
    "worker_count": expected,
    "total_cycles": int(health.get("total_cycles", 0)),
    "progress_units": int(health.get("progress_units", health.get("validated_migrations", 0))),
    "pids_current": int((cgroup / "pids.current").read_text()),
    "pids_max": (cgroup / "pids.max").read_text().strip(),
}
temporary = output_path.with_suffix(".tmp")
temporary.write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n")
temporary.chmod(0o600)
temporary.replace(output_path)
print(
    f"A_TRUST_OK=1 supervisor={trust['supervisor']['pid']} workers={expected} "
    f"cycles={trust['total_cycles']} pids_current={trust['pids_current']} pids_max={trust['pids_max']}"
)
PY
