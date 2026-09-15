#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
/usr/bin/setpriv --reuid=agentb --regid=agentb --init-groups -- python3 - "$PIDFILE" "$STATE_DIR/status.json" "$LOCK_KIND" "$A_SUBCOMMAND" "$PROGRESS_KEY" <<'PY'
import fcntl, json, os, pathlib, sys, time

pidfile, state_path, lock_kind, subcommand, progress_key = sys.argv[1:]
pidfile = pathlib.Path(pidfile)
pid = int(pidfile.read_text(encoding="ascii").strip())
proc = pathlib.Path("/proc") / str(pid)
raw = (proc / "stat").read_text(encoding="utf-8")
fields = raw[raw.rfind(")") + 2:].split()
if fields[0] == "Z":
    raise SystemExit("owner is a zombie")
cmdline = [part.decode(errors="replace") for part in (proc / "cmdline").read_bytes().split(b"\0") if part]
if subcommand not in cmdline:
    raise SystemExit("owner command is not the incumbent mode")
pid_stat = pidfile.stat()
fd_matches = []
fd_targets = []
for fd in (proc / "fd").iterdir():
    try:
        target = os.readlink(fd)
    except OSError:
        continue
    fd_targets.append(f"{fd.name}:{target}")
    try:
        current = fd.stat()
    except OSError:
        current = None
    if target == str(pidfile) or target == str(pidfile) + " (deleted)" or (current is not None and (current.st_dev, current.st_ino) == (pid_stat.st_dev, pid_stat.st_ino)):
        fd_matches.append(fd.name)
locks = []
lock_owner_fields = []
for line in pathlib.Path("/proc/locks").read_text(errors="replace").splitlines():
    parts = line.split()
    if len(parts) < 6 or parts[1] != lock_kind or parts[3] != "WRITE":
        continue
    try:
        inode = int(parts[5].rsplit(":", 1)[1])
    except ValueError:
        continue
    if inode == pid_stat.st_ino:
        locks.append(line)
        lock_owner_fields.append(parts[4])
probe_blocked = False
probe_error = ""
probe_fd = None
try:
    probe_fd = os.open(pidfile, os.O_RDWR)
    try:
        fcntl.lockf(probe_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        probe_blocked = True
    else:
        fcntl.lockf(probe_fd, fcntl.LOCK_UN)
finally:
    if probe_fd is not None:
        os.close(probe_fd)
state = json.loads(pathlib.Path(state_path).read_text(encoding="utf-8"))
if state.get("pid") != pid or int(state.get(progress_key, 0)) < 1:
    raise SystemExit("useful progress is not ready")
if time.time_ns() - int(state.get("heartbeat_ns", 0)) > 3_000_000_000:
    raise SystemExit("heartbeat is stale")
if not fd_matches or not (locks or probe_blocked):
    raise SystemExit("same-inode descriptor or kernel lock missing")
print(f"A_HEALTHY=1 pid={pid} progress={state[progress_key]} inode={pid_stat.st_ino} lock_kind={lock_kind} lock_owner={','.join(lock_owner_fields)} lock_probe_blocked={int(probe_blocked)} fd_targets={';'.join(fd_targets)}")
PY
