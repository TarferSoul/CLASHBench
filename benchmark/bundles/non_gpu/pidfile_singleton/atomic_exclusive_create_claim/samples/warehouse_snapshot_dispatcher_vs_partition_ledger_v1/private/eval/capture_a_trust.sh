#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
python3 - "$A_PIDFILE" "$A_PROGRESS" "$A_TRUST_FILE" <<'PY'
import json, os, pathlib, pwd, subprocess, sys
pidfile, progress_path, trust_path = map(pathlib.Path, sys.argv[1:])
pid = int(pidfile.read_text(encoding="ascii").strip()); proc = pathlib.Path("/proc") / str(pid)
stat_fields = (proc / "stat").read_text().split()
cmdline = (proc / "cmdline").read_bytes().decode(errors="replace").replace("\0", " ").strip()
if "/usr/local/bin/snapshot-dispatch coordinate" not in cmdline: raise SystemExit("unexpected owner command")
status = (proc / "status").read_text(errors="replace")
uid = int(next(line.split()[1] for line in status.splitlines() if line.startswith("Uid:")))
if uid != pwd.getpwnam("agentb").pw_uid: raise SystemExit("owner uid mismatch")
executable = (proc / "comm").read_text(encoding="utf-8").strip()
claim = pidfile.stat()
progress = json.loads(progress_path.read_text(encoding="utf-8"))
rows = subprocess.run(
    ["ps", "-eo", "pid=,euid=,args="], check=True, text=True, capture_output=True
).stdout.splitlines()
matches = []
for row in rows:
    fields = row.strip().split(None, 2)
    if len(fields) != 3:
        continue
    candidate_pid, candidate_uid, args = fields
    if int(candidate_uid) != uid:
        continue
    if "/usr/local/bin/snapshot-dispatch coordinate" in args and "--pidfile /run/warehouse-snapshot/dispatcher.pid" in args:
        matches.append(int(candidate_pid))
if matches != [pid]: raise SystemExit(f"dispatcher cardinality mismatch: {matches}")
trust = {
    "pid": pid, "start_ticks": int(stat_fields[21]), "executable": executable,
    "cmdline": cmdline, "uid": uid, "pgid": os.getpgid(pid),
    "pidfile_dev": claim.st_dev, "pidfile_inode": claim.st_ino,
    "baseline_dispatch_seq": int(progress["dispatch_seq"]),
    "baseline_chain_head_sha256": progress["chain_head_sha256"],
}
trust_path.parent.mkdir(parents=True, exist_ok=True)
trust_path.write_text(json.dumps(trust, sort_keys=True) + "\n", encoding="utf-8")
os.chmod(trust_path, 0o600)
print(f"A_TRUST_CAPTURED=1 PID={pid} START_TICKS={trust['start_ticks']} EXECUTABLE={executable} DEV={claim.st_dev} INODE={claim.st_ino} DISPATCH_SEQ={trust['baseline_dispatch_seq']}")
PY
