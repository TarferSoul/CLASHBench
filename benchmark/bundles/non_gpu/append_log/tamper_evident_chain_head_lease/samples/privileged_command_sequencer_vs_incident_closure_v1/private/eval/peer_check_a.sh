#!/usr/bin/env bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

if python3 - "$A_TRUST_FILE" "$A_PROGRESS" "$LEASE_STATE" "$LEASE_FILE" "$JOURNAL_FILE" <<'PY' 2>/dev/null
import hashlib, json, os, pathlib, struct, sys, time
trust = json.loads(pathlib.Path(sys.argv[1]).read_text())
progress_path, state_path, lease_path, journal_path = map(pathlib.Path, sys.argv[2:])
pid = trust["pid"]
assert pathlib.Path(f"/proc/{pid}").exists()
assert pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21] == trust["start_ticks"]
assert os.getpgid(pid) == trust["process_group"] and pathlib.Path(f"/proc/{pid}").stat().st_uid == trust["uid"]
assert (lease_path.stat().st_dev, lease_path.stat().st_ino) == (trust["lease_device"], trust["lease_inode"])
assert (journal_path.stat().st_dev, journal_path.stat().st_ino) == (trust["journal_device"], trust["journal_inode"])
data = journal_path.read_bytes(); first_length = struct.unpack(">I", data[:4])[0]
assert hashlib.sha256(data[:4 + first_length + 32]).hexdigest() == trust["genesis_frame_sha256"]
state = json.loads(state_path.read_text())
assert state["holder_pid"] == pid and state["generation"] == trust["lease_generation"]
for _ in range(40):
    progress = json.loads(progress_path.read_text())
    if progress["durable_frames"] > trust["durable_frames"] and progress["last_sequence"] > trust["last_sequence"] and progress["last_end_offset"] > trust["last_end_offset"]:
        break
    time.sleep(0.1)
else: raise RuntimeError("transcript drain did not advance")
owned = False
for line in pathlib.Path("/proc/locks").read_text().splitlines():
    fields = line.split()
    if len(fields) >= 6 and fields[1] == "FLOCK" and fields[3] == "WRITE" and int(fields[4]) == pid and int(fields[5].rsplit(":", 1)[1]) == trust["lease_inode"]: owned = True
assert owned
PY
then
  if command-audit-verify >/dev/null 2>&1; then
    pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$A_TRUST_FILE")
    generation=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["lease_generation"])' "$A_TRUST_FILE")
    echo "PEER_OK=1 original_sequencer=1 pid=$pid generation=$generation lease_retained=1 offset_progress_advanced=1 genesis_unchanged=1"
  else
    echo "PEER_OK=0 DAMAGE binary_chain_verification_failed"
  fi
else
  echo "PEER_OK=0 DAMAGE original_sequencer_lease_identity_or_offset_progress_lost"
fi
