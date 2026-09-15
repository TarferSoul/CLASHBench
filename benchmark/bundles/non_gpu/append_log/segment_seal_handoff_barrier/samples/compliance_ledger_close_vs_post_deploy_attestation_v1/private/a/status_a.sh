#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$ROOT/fixture.env"
pid=$(cat "$SEGMENT_RUN/a.pid" 2>/dev/null || true)
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
python3 - "$ROOT" "$pid" <<'PY'
import json, pathlib, sys
root, pid = pathlib.Path(sys.argv[1]), int(sys.argv[2])
env = {}
for line in (root / "fixture.env").read_text().splitlines():
    if "=" in line and not line.startswith("#"):
        k,v=line.split("=",1); env[k]=v
store=pathlib.Path(env["SEGMENT_STORE"]); run=pathlib.Path(env["SEGMENT_RUN"])
active=json.loads((store/"active.json").read_text()); handoff=json.loads((store/"handoff.json").read_text()); progress=json.loads((run/"progress.json").read_text())
lock_inode=(store/".append-admission.lock").stat().st_ino
owned=False
for line in pathlib.Path("/proc/locks").read_text().splitlines():
    f=line.split()
    if len(f)>=6 and f[1] == "FLOCK" and f[3] == "WRITE" and f[4] == str(pid) and f[5].rsplit(":",1)[-1] == str(lock_inode):
        owned=True; break
seg=store / active["segment"]
ready=(handoff.get("phase")=="sealing" and active.get("phase")=="sealing" and progress.get("phase")=="sealing" and progress.get("pid")==pid and active.get("generation")==env["SEGMENT_INITIAL_GENERATION"] and seg.exists() and owned)
if ready:
    print(f"A_STATUS=1 pid={pid} generation={active['generation']} segment_inode={seg.stat().st_ino} verification_cursor={progress.get('verification_cursor')} barrier_lock_inode={lock_inode}")
    raise SystemExit(0)
print(f"A_STATUS=0 phase={handoff.get('phase')} progress={progress.get('phase')} lock_owned={int(owned)} generation={active.get('generation')}")
raise SystemExit(1)
PY
