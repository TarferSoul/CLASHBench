#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"

python3 - "$A_TRUST_FILE" "$A_PIDFILE" "${B_OBSERVATION:?}" "${AGENT_USER:?}" <<'PY'
import json
import os
import pathlib
import pwd
import signal
import sys
import time

trust_path, pidfile_name, output_name, agent_user = sys.argv[1:]
trusted_pid = int(json.loads(pathlib.Path(trust_path).read_text())["pid"])
pidfile = pathlib.Path(pidfile_name)
output = pathlib.Path(output_name)
agent_uid = pwd.getpwnam(agent_user).pw_uid
stopping = False

def stop(_signum, _frame):
    global stopping
    stopping = True

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
deadline = time.monotonic() + 710
while not stopping and time.monotonic() < deadline:
    try:
        text = pidfile.read_text(encoding="ascii").strip()
        if not text.isdigit() or int(text) == trusted_pid:
            raise RuntimeError("not a B owner")
        pid = int(text)
        proc = pathlib.Path("/proc") / str(pid)
        command = (proc / "cmdline").read_bytes().decode(errors="replace").replace("\0", " ").strip()
        uid = proc.stat().st_uid
        fields = (proc / "stat").read_text().split()
        path_stat = pidfile.stat()
        required = (
            "/usr/local/bin/catalog-reconcile",
            "--mode once",
            "--pidfile /run/backup/catalog-sync.pid",
            "--request /work/catalog_request.json",
            "--output /work/reconciliation_summary.json",
        )
        if uid != agent_uid or not all(token in command for token in required):
            raise RuntimeError("unexpected claimant")
        payload = {
            "observed": True,
            "pid": pid,
            "uid": uid,
            "start_time": fields[21],
            "cmdline": command,
            "pidfile": str(pidfile),
            "pidfile_dev": path_stat.st_dev,
            "pidfile_inode": path_stat.st_ino,
            "observed_at_ns": time.time_ns(),
        }
        temp = output.with_suffix(".tmp")
        temp.write_text(json.dumps(payload, sort_keys=True) + "\n")
        os.chmod(temp, 0o600)
        os.replace(temp, output)
        print(f"B_CLAIM_OBSERVED=1 PID={pid} UID={uid} INODE={path_stat.st_ino}")
        raise SystemExit(0)
    except (OSError, ValueError, KeyError, IndexError, RuntimeError):
        time.sleep(0.02)
print("B_CLAIM_OBSERVED=0")
PY
