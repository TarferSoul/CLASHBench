#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$A_PIDFILE" "$A_STATE_DIR" "$A_TRUST_FILE" <<'PY'
import json
import os
import pathlib
import stat
import subprocess
import sys

pidfile, state_dir, trust_file = map(pathlib.Path, sys.argv[1:])
pid = int(pidfile.read_text(encoding="ascii").strip())
proc = pathlib.Path("/proc") / str(pid)
if not proc.exists():
    raise SystemExit("owner process is absent")
fields = (proc / "stat").read_text().split()
command = (proc / "cmdline").read_bytes().decode(errors="replace").replace("\0", " ").strip()
if "catalog-reconcile" not in command or "--mode daemon" not in command:
    raise SystemExit("owner command is not the expected catalog daemon")
status = (proc / "status").read_text(errors="replace")
uid = next((line.split()[1] for line in status.splitlines() if line.startswith("Uid:")), "")
pid_stat = pidfile.stat()
progress = json.loads((state_dir / "progress.json").read_text(encoding="utf-8"))
def process_exe(pid):
    try:
        return os.readlink(pathlib.Path("/proc") / str(pid) / "exe")
    except OSError:
        return subprocess.check_output(
            ["runuser", "-u", os.environ["AGENT_USER"], "--", "readlink", f"/proc/{pid}/exe"],
            text=True,
        ).strip()

trust = {
    "pid": pid,
    "start_time": fields[21],
    "exe": process_exe(pid),
    "cmdline": command,
    "uid": uid,
    "pgid": os.getpgid(pid),
    "sid": os.getsid(pid),
    "pidfile_dev": pid_stat.st_dev,
    "pidfile_inode": pid_stat.st_ino,
    "pidfile_uid": pid_stat.st_uid,
    "pidfile_gid": pid_stat.st_gid,
    "pidfile_mode": stat.S_IMODE(pid_stat.st_mode),
    "baseline_progress": int(progress.get("progress", 0)),
    "baseline_heartbeat_ns": int(progress.get("heartbeat_ns", 0)),
}
target = pathlib.Path(trust_file)
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps(trust, sort_keys=True) + "\n", encoding="utf-8")
os.chmod(target, 0o600)
print(f"A_TRUST_CAPTURED=1 PID={pid} START_TIME={trust['start_time']} DEV={pid_stat.st_dev} INODE={pid_stat.st_ino} PROGRESS={trust['baseline_progress']}")
PY
