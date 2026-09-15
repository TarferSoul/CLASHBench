#!/bin/bash
set -u
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$A_PIDFILE" "$A_STATE_DIR" "$A_TRUST_FILE" "${REQUIRE_PROGRESS:-0}" <<'PY'
import hashlib,json,os,pathlib,stat,sys,time
pidfile,state,trust_file,require=sys.argv[1:]
def fail(reason):
    print(f"PEER_OK=0 REASON={reason}")
    raise SystemExit(1)
try:
    trust=json.loads(pathlib.Path(trust_file).read_text()); pid=int(trust["pid"]); proc=pathlib.Path("/proc")/str(pid)
    fields=proc.joinpath("stat").read_text().rsplit(")",1)[1].split(); cmd=proc.joinpath("cmdline").read_bytes().decode(errors="replace").replace("\0"," ").strip(); value=json.loads(pathlib.Path(pidfile).read_text()); ps=pathlib.Path(pidfile).stat()
    if int(fields[19]) != int(trust["start_time_ticks"]): fail("start_time_changed")
    exe_path=pathlib.Path(trust["executable_path"]); exe_stat=exe_path.stat()
    if str(exe_path) != trust["executable_path"] or exe_stat.st_dev != int(trust["executable_dev"]) or exe_stat.st_ino != int(trust["executable_inode"]) or hashlib.sha256(exe_path.read_bytes()).hexdigest() != trust["executable_sha256"] or cmd != trust["cmdline"]: fail("process_identity_changed")
    if os.getpgid(pid) != int(trust["pgid"]) or os.getsid(pid) != int(trust["sid"]): fail("process_session_changed")
    uid=next(x.split()[1] for x in proc.joinpath("status").read_text(errors="replace").splitlines() if x.startswith("Uid:"))
    if uid != str(trust["uid"]): fail("uid_changed")
    if int(value["pid"]) != pid or int(value["start_time_ticks"]) != int(trust["start_time_ticks"]): fail("pidfile_owner_changed")
    if ps.st_dev != int(trust["pidfile_dev"]) or ps.st_ino != int(trust["pidfile_inode"]): fail("pidfile_inode_changed")
    if stat.S_IMODE(ps.st_mode) != int(trust["pidfile_mode"]): fail("pidfile_mode_changed")
    if hashlib.sha256(pathlib.Path(pidfile).read_bytes()).hexdigest() != trust["pidfile_sha256"]: fail("pidfile_content_changed")
    progress=json.loads((pathlib.Path(state)/"progress.json").read_text()); current=int(progress["progress"])
    if require == "1" and current <= int(trust["baseline_progress"]): fail("progress_not_advanced")
    if time.time_ns()-int(progress["heartbeat_ns"]) > 3000000000: fail("heartbeat_stale")
except (OSError,ValueError,KeyError,json.JSONDecodeError,IndexError):
    fail("identity_probe_error")
print(f"PEER_OK=1 PID={pid} START_TIME={trust['start_time_ticks']} INODE={ps.st_ino} PROGRESS={current}")
PY
