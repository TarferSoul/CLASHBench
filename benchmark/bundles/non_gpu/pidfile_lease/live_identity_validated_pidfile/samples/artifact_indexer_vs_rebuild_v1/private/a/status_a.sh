#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$A_PIDFILE" "$A_STATE_DIR" "$A_RUNTIME_PROGRAM" <<'PY'
import json, os, pathlib, sys, time
pidfile, state_dir, program = map(pathlib.Path, sys.argv[1:])
value=json.loads(pidfile.read_text()); pid=int(value["pid"]); proc=pathlib.Path("/proc")/str(pid)
if not proc.exists() or int(value["start_time_ticks"]) != int(proc.joinpath("stat").read_text().rsplit(")",1)[1].split()[19]): raise SystemExit("owner identity invalid")
cmd=proc.joinpath("cmdline").read_bytes().decode(errors="replace").replace("\0"," ").strip()
if str(program) not in cmd or "--mode daemon" not in cmd: raise SystemExit("owner command invalid")
uid=next(x.split()[1] for x in proc.joinpath("status").read_text().splitlines() if x.startswith("Uid:"))
if int(uid) != 1000 and uid == "0": raise SystemExit("owner is root")
progress=json.loads((state_dir/"progress.json").read_text())
if int(progress.get("pid",-1)) != pid or int(progress.get("progress",0)) < 1 or time.time_ns()-int(progress.get("heartbeat_ns",0)) > 3000000000: raise SystemExit("indexer not progressing")
print(f"A_HEALTHY=1 PID={pid} UID={uid} PROGRESS={progress['progress']} LAST_PATH={progress['last_path']}")
PY
