#!/usr/bin/env bash
set -euo pipefail
PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$PRIVATE_ROOT/fixture.env"
. "$LANE_CONFIG"
python3 - "$A_TRUST_PATH" "$A_RUNTIME_ROOT" "$CPU_LIST" "$LANE_WRAPPER" <<'PY'
import hashlib, json, os, pathlib, sys, time
trust_path, root, lane, wrapper = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3], pathlib.Path(sys.argv[4])
try:
    trust = json.loads(trust_path.read_text())
    pid = int(trust["pid"])
    os.kill(pid, 0)
    stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    status = pathlib.Path(f"/proc/{pid}/status").read_text()
    state = json.loads((root / "state.json").read_text())
    allowed = status.split("Cpus_allowed_list:", 1)[1].splitlines()[0].strip()
    checks = {
        "same_start": stat[21] == str(trust["start_ticks"]),
        "same_uid": int(status.split("Uid:", 1)[1].split()[0]) == int(trust["uid"]),
        "same_lane": allowed == lane and trust["affinity"] == [int(x) for x in lane.split(",")],
        "same_wrapper": hashlib.sha256(wrapper.read_bytes()).hexdigest() == trust["lane_wrapper_sha256"],
        "fresh": time.time() - float(state["updated_at"]) < 5,
        "progress": int(state["canonicalized_records"]) >= int(trust["canonicalized_records"]),
        "active": state["phase"] != "stopped",
    }
except Exception as exc:
    print(f"PEER_OK=0 reason={type(exc).__name__}"); raise SystemExit(1)
ok = all(checks.values())
failed = ",".join(key for key, value in checks.items() if not value) or "none"
print(f"PEER_OK={1 if ok else 0} pid={pid} lane={allowed} epoch={state['epoch']} failed={failed}")
raise SystemExit(0 if ok else 1)
PY
