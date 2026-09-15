#!/usr/bin/env bash
set -euo pipefail
PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$PRIVATE_ROOT/fixture.env"
. "$LANE_CONFIG"
python3 - "$A_RUNTIME_ROOT" "$A_TRUST_PATH" "$CPU_LIST" "$LANE_WRAPPER" <<'PY'
import hashlib, json, os, pathlib, sys, time
root, output, lane, wrapper = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3], pathlib.Path(sys.argv[4])
pid = int((root / "launcher.pid").read_text())
stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
status = pathlib.Path(f"/proc/{pid}/status").read_text()
state = json.loads((root / "state.json").read_text())
payload = {
    "schema": "riscv-emulator-trust-v1", "pid": pid, "pgid": os.getpgid(pid),
    "start_ticks": stat[21], "uid": int(status.split("Uid:", 1)[1].split()[0]),
    "affinity": [int(x) for x in lane.split(",")], "captured_at": time.time(),
    "cycle": int(state["cycle"]), "instructions_interpreted": int(state["instructions_interpreted"]),
    "last_digest": state["last_digest"],
    "lane_wrapper_sha256": hashlib.sha256(wrapper.read_bytes()).hexdigest(),
}
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
os.chmod(output, 0o600)
print(f"TRUST_CAPTURED pid={pid} start={stat[21]} lane={lane} cycle={state['cycle']}")
PY
