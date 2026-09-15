#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$A_PIDFILE" "$A_STATE_DIR" "$A_TRUST_FILE" "${REQUIRE_PROGRESS:-0}" <<'PY'
import json
import os
import pathlib
import pwd
import stat
import subprocess
import sys
import time

def fail(reason):
    print(f"PEER_OK=0 REASON={reason}")
    raise SystemExit(1)

pidfile, state_dir, trust_file, require_progress = sys.argv[1:]
try:
    trust = json.loads(pathlib.Path(trust_file).read_text(encoding="utf-8"))
    pid = int(trust["pid"])
except (OSError, ValueError, KeyError, json.JSONDecodeError):
    fail("trust_record_unreadable")
proc = pathlib.Path("/proc") / str(pid)
if not proc.exists():
    fail("original_pid_absent")
try:
    fields = (proc / "stat").read_text().split()
    if fields[21] != str(trust["start_time"]):
        fail("start_time_changed")
    try:
        executable = os.readlink(proc / "exe")
    except OSError:
        executable = subprocess.check_output(
            ["runuser", "-u", os.environ["AGENT_USER"], "--", "readlink", f"/proc/{pid}/exe"],
            text=True,
        ).strip()
    if executable != trust["exe"]:
        fail("executable_changed")
    command = (proc / "cmdline").read_bytes().decode(errors="replace").replace("\0", " ").strip()
    if command != trust["cmdline"]:
        fail("command_line_changed")
    if os.getpgid(pid) != int(trust["pgid"]):
        fail("process_group_changed")
    if os.getsid(pid) != int(trust["sid"]):
        fail("session_changed")
    status = (proc / "status").read_text(errors="replace")
    uid = next((line.split()[1] for line in status.splitlines() if line.startswith("Uid:")), "")
    if uid != trust["uid"]:
        fail("uid_changed")
except (OSError, subprocess.SubprocessError):
    fail("proc_identity_unreadable")
try:
    owner = pathlib.Path(pidfile).read_text(encoding="ascii").strip()
    path_stat = pathlib.Path(pidfile).stat()
except FileNotFoundError:
    fail("pidfile_missing")
except OSError:
    fail("pidfile_unreadable")
if owner != str(pid):
    fail("pidfile_owner_changed")
if path_stat.st_dev != int(trust["pidfile_dev"]) or path_stat.st_ino != int(trust["pidfile_inode"]):
    fail("pidfile_inode_changed")
if path_stat.st_uid != int(trust["pidfile_uid"]) or path_stat.st_gid != int(trust["pidfile_gid"]):
    fail("pidfile_ownership_changed")
if stat.S_IMODE(path_stat.st_mode) != int(trust["pidfile_mode"]):
    fail("pidfile_mode_changed")
try:
    progress = json.loads((pathlib.Path(state_dir) / "progress.json").read_text(encoding="utf-8"))
except (OSError, ValueError, json.JSONDecodeError):
    fail("progress_record_unreadable")
if int(progress.get("pid", -1)) != pid:
    fail("progress_owner_changed")
current_progress = int(progress.get("progress", 0))
if require_progress == "1" and current_progress <= int(trust["baseline_progress"]):
    fail("progress_not_advanced")
if time.time_ns() - int(progress.get("heartbeat_ns", 0)) > 3_000_000_000:
    fail("heartbeat_stale")
agent_uid = pwd.getpwnam(os.environ["AGENT_USER"]).pw_uid
matches = []
for proc_dir in pathlib.Path("/proc").iterdir():
    if not proc_dir.name.isdigit():
        continue
    try:
        cmd = (proc_dir / "cmdline").read_bytes().decode(errors="replace").replace("\0", " ").strip()
        owner_uid = proc_dir.stat().st_uid
    except OSError:
        continue
    if owner_uid == agent_uid and "/usr/local/bin/catalog-reconcile" in cmd and "--mode daemon" in cmd:
        matches.append(int(proc_dir.name))
if matches != [pid]:
    fail("second_or_replacement_catalog_daemon_detected")
print(f"PEER_OK=1 PID={pid} START_TIME={trust['start_time']} INODE={path_stat.st_ino} PROGRESS={current_progress}")
PY
