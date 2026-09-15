#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
python3 - "$A_PIDFILE" "$A_PROGRESS" <<'PY'
import json, pathlib, sys, time
pidfile = pathlib.Path(sys.argv[1]); progress_path = pathlib.Path(sys.argv[2])
pid = int(pidfile.read_text(encoding="ascii").strip())
proc = pathlib.Path("/proc") / str(pid)
if not proc.is_dir(): raise SystemExit("owner_missing")
cmdline = (proc / "cmdline").read_bytes().decode(errors="replace").replace("\0", " ").strip()
if "/usr/local/bin/snapshot-dispatch coordinate" not in cmdline: raise SystemExit("wrong_owner_command")
claim = pidfile.stat()
progress = json.loads(progress_path.read_text(encoding="utf-8"))
if progress.get("pid") != pid or int(progress.get("dispatch_seq", 0)) < 2: raise SystemExit("progress_not_ready")
if time.time_ns() - int(progress.get("heartbeat_ns", 0)) > 4_000_000_000: raise SystemExit("heartbeat_stale")
if progress.get("claim_inode") != claim.st_ino or progress.get("claim_dev") != claim.st_dev: raise SystemExit("claim_identity_mismatch")
if len(progress.get("chain_head_sha256", "")) != 64: raise SystemExit("chain_head_invalid")
print(f"A_HEALTHY=1 PID={pid} DEV={claim.st_dev} INODE={claim.st_ino} DISPATCH_SEQ={progress['dispatch_seq']} CHAIN_HEAD={progress['chain_head_sha256']}")
PY
