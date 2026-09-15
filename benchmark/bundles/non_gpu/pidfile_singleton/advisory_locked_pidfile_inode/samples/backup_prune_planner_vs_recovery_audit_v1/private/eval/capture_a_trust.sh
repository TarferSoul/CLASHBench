#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
observation="$RESULT_ROOT/evidence/a_trust_observation.json"
bash "$CASE_PRIVATE_ROOT/eval/observe_current.sh" "$observation"
python3 - "$observation" "$TRUST_FILE" "$A_SUBCOMMAND" "$PROGRESS_KEY" <<'PY'
import json, os, pathlib, sys

observed_path, trust_path, subcommand, progress_key = sys.argv[1:]
value = json.loads(pathlib.Path(observed_path).read_text(encoding="utf-8"))
if value["process_state"] == "Z" or subcommand not in value["cmdline"]:
    raise SystemExit("wrong incumbent process identity")
if not value["descriptor_fds"] or not (value["lock_records"] or value.get("lock_probe_blocked")):
    raise SystemExit("incumbent does not hold the canonical inode lock")
state = value["state"]
if state.get("pid") != value["pid"] or int(state.get(progress_key, 0)) < 1:
    raise SystemExit("incumbent progress is not established")
value["baseline_progress"] = int(state[progress_key])
value["baseline_heartbeat_ns"] = int(state["heartbeat_ns"])
target = pathlib.Path(trust_path)
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")
os.chmod(target, 0o600)
print(f"A_TRUST_CAPTURED=1 pid={value['pid']} start_ticks={value['start_ticks']} device={value['pidfile_device']} inode={value['pidfile_inode']} lock_kind={value['lock_kind']} progress={value['baseline_progress']}")
PY
