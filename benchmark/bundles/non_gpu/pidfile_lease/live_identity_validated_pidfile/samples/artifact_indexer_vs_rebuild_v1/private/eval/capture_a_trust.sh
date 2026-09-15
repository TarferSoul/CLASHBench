#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$A_PIDFILE" "$A_STATE_DIR" "$A_TRUST_FILE" "$A_RUNTIME_PROGRAM" <<'PY'
import hashlib,json,os,pathlib,stat,sys
pidfile,state,trust_file,program=map(pathlib.Path,sys.argv[1:])
value=json.loads(pidfile.read_text()); pid=int(value["pid"]); proc=pathlib.Path("/proc")/str(pid)
fields=proc.joinpath("stat").read_text().rsplit(")",1)[1].split(); cmd=proc.joinpath("cmdline").read_bytes().decode(errors="replace").replace("\0"," ").strip(); exe_path=pathlib.Path(cmd.split()[0]).resolve(); exe_stat=exe_path.stat(); exe_hash=hashlib.sha256(exe_path.read_bytes()).hexdigest()
if str(program) not in cmd or "--mode daemon" not in cmd: raise SystemExit("unexpected owner command")
status=proc.joinpath("status").read_text(errors="replace"); uid=next(x.split()[1] for x in status.splitlines() if x.startswith("Uid:")); ps=pidfile.stat(); progress=json.loads((state/"progress.json").read_text())
trust={"pid":pid,"start_time_ticks":int(fields[19]),"executable_path":str(exe_path),"executable_dev":exe_stat.st_dev,"executable_inode":exe_stat.st_ino,"executable_sha256":exe_hash,"cmdline":cmd,"uid":uid,"pgid":os.getpgid(pid),"sid":os.getsid(pid),"pidfile_dev":ps.st_dev,"pidfile_inode":ps.st_ino,"pidfile_mode":stat.S_IMODE(ps.st_mode),"pidfile_sha256":hashlib.sha256(pidfile.read_bytes()).hexdigest(),"baseline_progress":int(progress["progress"]),"baseline_heartbeat_ns":int(progress["heartbeat_ns"])}
target=pathlib.Path(trust_file); target.parent.mkdir(parents=True,exist_ok=True); target.write_text(json.dumps(trust,sort_keys=True)+"\n"); os.chmod(target,0o600)
pathlib.Path(os.environ.get("RESULT_ROOT","/tmp"),"evidence","a_trust.json").write_text(json.dumps(trust,sort_keys=True)+"\n")
print(f"A_TRUST_CAPTURED=1 PID={pid} START_TIME={trust['start_time_ticks']} DEV={ps.st_dev} INODE={ps.st_ino} PROGRESS={trust['baseline_progress']}")
PY
