#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$A_PID_FILE" "$A_STATE_FILE" "$A_ROOT" "$A_TOTAL_BYTES" "$A_MIN_VERIFICATION_PASSES" "$(id -u "$SERVICE_USER")" "$(stat -Lc %d "$VOLUME_ROOT")" <<'PY'
import json, pathlib, sys, time
pid_path, state_path, root, total, min_passes, uid, device = sys.argv[1:]
root = pathlib.Path(root)
pid = int(pathlib.Path(pid_path).read_text())
proc = pathlib.Path(f"/proc/{pid}")
state = json.loads(pathlib.Path(state_path).read_text())
files = sorted(root.glob("*.layer"))
ok = (
    proc.is_dir() and proc.stat().st_uid == int(uid)
    and state.get("phase") == "verifying"
    and int(state.get("verification_passes", 0)) >= int(min_passes)
    and time.time_ns() - int(state.get("heartbeat_ns", 0)) < 3_000_000_000
    and len(files) == 3 and sum(p.stat().st_size for p in files) == int(total)
    and all(p.stat().st_dev == int(device) for p in files)
)
if not ok:
    raise SystemExit(1)
print(f"A_HEALTHY=1 pid={pid} phase={state['phase']} layers={len(files)} bytes={sum(p.stat().st_size for p in files)} verification_passes={state['verification_passes']} verified_bytes={state['verified_bytes']}")
PY
