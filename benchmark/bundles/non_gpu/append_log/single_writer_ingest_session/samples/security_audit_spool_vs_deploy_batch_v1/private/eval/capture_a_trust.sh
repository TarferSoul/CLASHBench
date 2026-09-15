#!/usr/bin/env bash
set -euo pipefail
PRIVATE_CASE=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
: "${TRUST_FILE:?}"
python3 - "$TRUST_FILE" "$COLLECTOR_PID_FILE" "$A_PID_FILE" "$STATE_PATH" "$A_CURSOR_PATH" "$SOCKET_PATH" "$LEDGER_PATH" "$A_SESSION_ID" <<'PY'
import json, os, pathlib, subprocess, sys, time
out, collector_pid_file, a_pid_file, state_path, cursor_path, socket_path, ledger_path, session_id = sys.argv[1:]
collector_pid = int(pathlib.Path(collector_pid_file).read_text())
a_pid = int(pathlib.Path(a_pid_file).read_text())
state = json.loads(pathlib.Path(state_path).read_text())
cursor = json.loads(pathlib.Path(cursor_path).read_text())
def starttime(pid):
    text = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(text[text.rfind(")") + 2:].split()[19])
agent_uid = int(os.popen("id -u agentb").read())
assert pathlib.Path(f"/proc/{collector_pid}").stat().st_uid == agent_uid
assert pathlib.Path(f"/proc/{a_pid}").stat().st_uid == agent_uid
assert state["collector_pid"] == collector_pid
assert state["active_session"]["session_id"] == session_id
assert state["active_session"]["client_pid"] == a_pid
ledger_stat = os.stat(ledger_path)
probe = r'''import json, os, pathlib, sys
rows=[]
for fd in pathlib.Path(f"/proc/{sys.argv[1]}/fd").iterdir():
    try: stat=os.stat(fd)
    except OSError: continue
    rows.append([int(fd.name), stat.st_dev, stat.st_ino])
print(json.dumps(rows))'''
fd_rows = json.loads(subprocess.check_output(["runuser", "-u", "agentb", "--", "python3", "-c", probe, str(collector_pid)], text=True))
matching_fds = [fd for fd, dev, inode in fd_rows if (dev, inode) == (ledger_stat.st_dev, ledger_stat.st_ino)]
assert matching_fds
trust = {
    "captured_ns": time.time_ns(), "agent_uid": agent_uid,
    "collector_pid": collector_pid, "collector_starttime": starttime(collector_pid),
    "a_pid": a_pid, "a_starttime": starttime(a_pid),
    "a_session_id": session_id, "a_cursor_baseline": int(cursor["durable_records"]),
    "socket_dev": os.stat(socket_path).st_dev, "socket_inode": os.stat(socket_path).st_ino,
    "ledger_dev": ledger_stat.st_dev, "ledger_inode": ledger_stat.st_ino,
    "collector_ledger_fds": matching_fds,
}
pathlib.Path(out).write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n")
os.chmod(out, 0o600)
print(f"TRUST_OK=1 collector_pid={collector_pid} a_pid={a_pid} session={session_id} cursor={cursor['durable_records']} socket_inode={trust['socket_inode']} ledger_inode={trust['ledger_inode']}")
PY
