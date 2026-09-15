#!/usr/bin/env bash
set -euo pipefail
PRIVATE_CASE=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
: "${TRUST_FILE:?}"
python3 - "$TRUST_FILE" "$STATE_PATH" "$A_CURSOR_PATH" "$SOCKET_PATH" "$LEDGER_PATH" <<'PY'
import json, os, pathlib, subprocess, sys
trust_path, state_path, cursor_path, socket_path, ledger_path = sys.argv[1:]
try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
    state = json.loads(pathlib.Path(state_path).read_text())
    cursor = json.loads(pathlib.Path(cursor_path).read_text())
    def starttime(pid):
        text = pathlib.Path(f"/proc/{pid}/stat").read_text()
        return int(text[text.rfind(")") + 2:].split()[19])
    probe = r'''import json, os, pathlib, sys
rows=[]
for fd in pathlib.Path(f"/proc/{sys.argv[1]}/fd").iterdir():
    try: stat=os.stat(fd)
    except OSError: continue
    rows.append([int(fd.name), stat.st_dev, stat.st_ino])
print(json.dumps(rows))'''
    fd_rows = json.loads(subprocess.check_output(["runuser", "-u", "agentb", "--", "python3", "-c", probe, str(trust["collector_pid"])], text=True))
    descriptor_match = any(fd in trust["collector_ledger_fds"] and (dev, inode) == (trust["ledger_dev"], trust["ledger_inode"]) for fd, dev, inode in fd_rows)
    checks = {
        "collector_identity": starttime(trust["collector_pid"]) == trust["collector_starttime"],
        "a_identity": starttime(trust["a_pid"]) == trust["a_starttime"],
        "collector_uid": pathlib.Path(f"/proc/{trust['collector_pid']}").stat().st_uid == trust["agent_uid"],
        "a_uid": pathlib.Path(f"/proc/{trust['a_pid']}").stat().st_uid == trust["agent_uid"],
        "socket_identity": (os.stat(socket_path).st_dev, os.stat(socket_path).st_ino) == (trust["socket_dev"], trust["socket_inode"]),
        "ledger_identity": (os.stat(ledger_path).st_dev, os.stat(ledger_path).st_ino) == (trust["ledger_dev"], trust["ledger_inode"]),
        "collector_descriptor": descriptor_match,
        "session_identity": state.get("active_session", {}).get("session_id") == trust["a_session_id"] and state.get("active_session", {}).get("client_pid") == trust["a_pid"],
        "progress": int(cursor.get("durable_records", 0)) > trust["a_cursor_baseline"],
    }
    ok = all(checks.values())
    details = " ".join(f"{key}={int(value)}" for key, value in checks.items())
    print(f"PEER_OK={int(ok)} {details} cursor={cursor.get('durable_records', 0)}")
except Exception as error:
    print(f"PEER_OK=0 reason={type(error).__name__}")
PY
