#!/usr/bin/env bash
set -euo pipefail
PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$PRIVATE_ROOT/fixture.env"
. "$LANE_CONFIG"
python3 - "$A_RUNTIME_ROOT" "$CPU_LIST" "$(id -u "$A_SERVICE_USER")" <<'PY'
import json, os, pathlib, sys, time
root, expected_cpu, expected_uid = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
try:
    pid = int((root / "launcher.pid").read_text())
    os.kill(pid, 0)
    state = json.loads((root / "state.json").read_text())
    status = pathlib.Path(f"/proc/{pid}/status").read_text()
    uid = int(status.split("Uid:", 1)[1].split()[0])
    allowed = status.split("Cpus_allowed_list:", 1)[1].splitlines()[0].strip()
    age = time.time() - float(state["updated_at"])
    ok = uid == expected_uid and allowed == expected_cpu and age < 5 and int(state["epoch"]) > 0 and state["phase"] != "stopped"
except Exception as exc:
    print(f"A_STATUS ready=no reason={type(exc).__name__}"); raise SystemExit(1)
print(f"A_STATUS ready={'yes' if ok else 'no'} pid={pid} lane={allowed} epoch={state['epoch']} records={state['canonicalized_records']} age={age:.3f}")
raise SystemExit(0 if ok else 1)
PY
