#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
output=${1:?set output path}
/usr/bin/setpriv --reuid=agentb --regid=agentb --init-groups -- python3 - "$PIDFILE" "$STATE_DIR/status.json" "$LOCK_KIND" <<'PY' > "$output"
import fcntl, hashlib, json, os, pathlib, stat, sys, time

pidfile, state_path, lock_kind = sys.argv[1:]
pidfile = pathlib.Path(pidfile)
pid_bytes = pidfile.read_bytes()
pid = int(pid_bytes.decode("ascii").strip())
proc = pathlib.Path("/proc") / str(pid)
raw = (proc / "stat").read_text(encoding="utf-8")
fields = raw[raw.rfind(")") + 2:].split()
if fields[0] == "Z":
    raise SystemExit("owner is a zombie")
cmdline = [part.decode(errors="replace") for part in (proc / "cmdline").read_bytes().split(b"\0") if part]
status_lines = (proc / "status").read_text(errors="replace").splitlines()
uid = int(next(line.split()[1] for line in status_lines if line.startswith("Uid:")))
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
        fd_matches.append(int(fd.name))
lock_records = []
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
        lock_records.append(line)
        lock_owner_fields.append(parts[4])
probe_blocked = False
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
print(json.dumps({
    "pid": pid,
    "start_ticks": int(fields[19]),
    "process_state": fields[0],
    "pgid": int(fields[2]),
    "session": int(fields[3]),
    "uid": uid,
    "exe": os.path.realpath(proc / "exe"),
    "cmdline": cmdline,
    "pidfile_device": pid_stat.st_dev,
    "pidfile_inode": pid_stat.st_ino,
    "pidfile_mode": stat.S_IMODE(pid_stat.st_mode),
    "pidfile_sha256": hashlib.sha256(pid_bytes).hexdigest(),
    "descriptor_fds": sorted(fd_matches),
    "descriptor_targets": fd_targets,
    "lock_kind": lock_kind,
    "lock_records": lock_records,
    "lock_owner_fields": lock_owner_fields,
    "lock_probe_blocked": probe_blocked,
    "state": state,
    "observed_at_ns": time.time_ns(),
}, sort_keys=True))
PY
