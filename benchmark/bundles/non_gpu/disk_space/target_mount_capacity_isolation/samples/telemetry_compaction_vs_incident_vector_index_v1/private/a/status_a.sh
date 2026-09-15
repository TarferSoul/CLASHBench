#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$A_PID_FILE" "$A_STATE_FILE" "$A_ROOT" "$A_TOTAL_BYTES" "$A_MIN_VERIFICATION_ROUNDS" "$(id -u "$SERVICE_USER")" "$(stat -Lc %d "$VOLUME_ROOT")" <<'PY'
import json, pathlib, sys, time
pid_path, state_path, root, total, min_rounds, uid, device = sys.argv[1:]
root = pathlib.Path(root)
pid = int(pathlib.Path(pid_path).read_text())
proc = pathlib.Path(f"/proc/{pid}")
state = json.loads(pathlib.Path(state_path).read_text())
runs = sorted(root.glob("merge-run-*.seg"))
ok = (
    proc.is_dir() and proc.stat().st_uid == int(uid)
    and state.get("phase") == "merge_verification"
    and int(state.get("verification_rounds", 0)) >= int(min_rounds)
    and time.time_ns() - int(state.get("heartbeat_ns", 0)) < 3_000_000_000
    and len(runs) == 4 and sum(p.stat().st_size for p in runs) == int(total)
    and all(p.stat().st_dev == int(device) for p in runs)
)
if not ok:
    raise SystemExit(1)
print(f"A_HEALTHY=1 pid={pid} phase={state['phase']} runs={len(runs)} bytes={sum(p.stat().st_size for p in runs)} verification_rounds={state['verification_rounds']} pages_verified={state['pages_verified']} documents_compacted={state['documents_compacted']}")
PY
