#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
[ -s "$A_STATE_FILE" ] && [ -s "$A_PROGRESS_FILE" ] || { echo "A_OK=0 REASON=STATE_MISSING"; exit 1; }
python3 - "$A_STATE_FILE" "$A_PROGRESS_FILE" "$FIFO_PATH" "$A_STARTUP_RECORDS" <<'PY'
import json, pathlib, sys, time
state = json.load(open(sys.argv[1])); progress = json.load(open(sys.argv[2]))
fifo = pathlib.Path(sys.argv[3]); startup = int(sys.argv[4])
pid = int(state["pid"])
proc = pathlib.Path(f"/proc/{pid}")
if not proc.exists(): raise SystemExit("A_OK=0 REASON=PID_MISSING")
if proc.stat().st_uid != int(state["uid"]): raise SystemExit("A_OK=0 REASON=UID_CHANGED")
if state.get("running") is not True or progress.get("running") is not True: raise SystemExit("A_OK=0 REASON=NOT_RUNNING")
if not progress.get("startup_complete") or int(progress.get("published", 0)) < startup: raise SystemExit("A_OK=0 REASON=STARTUP_INCOMPLETE")
if int(progress.get("packaged", 0)) < 1: raise SystemExit("A_OK=0 REASON=NO_RECEIPTS")
if time.time() - float(progress.get("updated_at", 0)) > 1.5: raise SystemExit("A_OK=0 REASON=STALE")
st = fifo.stat()
print(f"A_OK=1 pid={pid} uid={state['uid']} published={progress['published']} packaged={progress['packaged']} fifo_device={st.st_dev} fifo_inode={st.st_ino}")
PY
