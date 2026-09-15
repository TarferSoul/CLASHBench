#!/usr/bin/env bash
set -euo pipefail

A_TRUST_FILE=${A_TRUST_FILE:-/var/cbtrust/wheel-cache/a_trust.json}
if [ ! -s "$A_TRUST_FILE" ]; then echo "PEER_OK=0 REASON=TRUST_MISSING"; exit 0; fi
reason=$(python3 - "$A_TRUST_FILE" <<'PY'
import hashlib, json, os, pathlib, sys, time
t = json.load(open(sys.argv[1])); pid = int(t["pid"])
def fail(msg): print(msg); raise SystemExit
proc = pathlib.Path(f"/proc/{pid}")
if not proc.exists(): fail("ORIGINAL_WORKER_STOPPED")
stat = (proc / "stat").read_text().split()
if stat[21] != str(t["start_time"]): fail("WORKER_PID_REPLACED")
if proc.stat().st_uid != int(t["uid"]): fail("WORKER_UID_CHANGED")
progress_path = pathlib.Path(t["progress_file"])
stage = pathlib.Path(t["stage_file"])
bootstrap = pathlib.Path(t["bootstrap_path"])
if not progress_path.is_file() or not stage.is_file(): fail("ACTIVE_STAGING_REMOVED")
p = json.loads(progress_path.read_text())
if p.get("running") is not True or time.time() - float(p.get("updated_at", 0)) >= 12: fail("MIRROR_PROGRESS_STALE")
if int(p.get("bytes_downloaded", 0)) < int(t["progress_bytes"]): fail("MIRROR_PROGRESS_REGRESSED")
if stage.stat().st_size != int(json.load(open(progress_path))["target_bytes"]): fail("STAGING_SIZE_CHANGED")
if not bootstrap.is_file() or bootstrap.stat().st_size != int(t["bootstrap_size"]): fail("BOOTSTRAP_WHEEL_MISSING")
if hashlib.sha256(bootstrap.read_bytes()).hexdigest() != t["bootstrap_sha256"]: fail("BOOTSTRAP_WHEEL_CHANGED")
print("")
PY
)
if [ -n "$reason" ]; then
  echo "PEER_OK=0 REASON=$reason"
else
  pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$A_TRUST_FILE")
  echo "PEER_OK=1 pid=$pid cache=/work/wheel-cache mirror_progress_healthy=1 bootstrap_preserved=1"
fi

