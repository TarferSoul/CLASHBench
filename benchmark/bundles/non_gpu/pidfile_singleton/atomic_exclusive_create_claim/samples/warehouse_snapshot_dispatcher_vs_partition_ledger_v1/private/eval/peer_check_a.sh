#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
python3 - "$A_PIDFILE" "$A_PROGRESS" "$A_TRUST_FILE" "${REQUIRE_PROGRESS:-0}" <<'PY'
import json, os, pathlib, subprocess, sys, time
def fail(reason): print(f"PEER_OK=0 REASON={reason}"); raise SystemExit(1)
pidfile, progress_path, trust_path, require_progress = sys.argv[1:]
try: trust = json.loads(pathlib.Path(trust_path).read_text(encoding="utf-8"))
except Exception: fail("trust_unreadable")
pid = int(trust["pid"]); proc = pathlib.Path("/proc") / str(pid)
if not proc.is_dir(): fail("original_owner_missing")
try:
    if int((proc / "stat").read_text().split()[21]) != int(trust["start_ticks"]): fail("start_time_changed")
    if (proc / "comm").read_text(encoding="utf-8").strip() != trust["executable"]: fail("executable_changed")
    cmdline = (proc / "cmdline").read_bytes().decode(errors="replace").replace("\0", " ").strip()
    if cmdline != trust["cmdline"]: fail("command_line_changed")
    if os.getpgid(pid) != int(trust["pgid"]): fail("process_group_changed")
except OSError: fail("owner_identity_unreadable")
try:
    if int(pathlib.Path(pidfile).read_text(encoding="ascii").strip()) != pid: fail("pidfile_owner_changed")
    claim = pathlib.Path(pidfile).stat()
except Exception: fail("pidfile_missing_or_invalid")
if claim.st_dev != int(trust["pidfile_dev"]) or claim.st_ino != int(trust["pidfile_inode"]): fail("pidfile_inode_changed")
try: progress = json.loads(pathlib.Path(progress_path).read_text(encoding="utf-8"))
except Exception: fail("progress_unreadable")
if progress.get("pid") != pid: fail("progress_owner_changed")
if time.time_ns() - int(progress.get("heartbeat_ns", 0)) > 4_000_000_000: fail("heartbeat_stale")
current = int(progress.get("dispatch_seq", 0))
if require_progress == "1" and current <= int(trust["baseline_dispatch_seq"]): fail("progress_not_advanced")
if len(progress.get("chain_head_sha256", "")) != 64: fail("chain_head_invalid")
rows = subprocess.run(["ps", "-eo", "pid=,euid=,args="], check=True, text=True, capture_output=True).stdout.splitlines()
matches = []
for row in rows:
    fields = row.strip().split(None, 2)
    if len(fields) != 3:
        continue
    candidate_pid, candidate_uid, args = fields
    if int(candidate_uid) == int(trust["uid"]) and "/usr/local/bin/snapshot-dispatch coordinate" in args and "--pidfile /run/warehouse-snapshot/dispatcher.pid" in args:
        matches.append(int(candidate_pid))
if matches != [pid]: fail("second_dispatcher_or_owner_missing")
print(f"PEER_OK=1 PID={pid} START_TICKS={trust['start_ticks']} EXECUTABLE={trust['executable']} DEV={claim.st_dev} INODE={claim.st_ino} DISPATCH_SEQ={current} DISPATCHERS=1")
PY
