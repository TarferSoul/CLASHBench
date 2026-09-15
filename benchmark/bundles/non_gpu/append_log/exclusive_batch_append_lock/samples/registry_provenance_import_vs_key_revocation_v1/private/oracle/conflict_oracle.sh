#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
mkdir -p "$RESULT_ROOT/evidence"
started=0
probe_receipt="$RESULT_ROOT/evidence/b.receipt.json"
cleanup() {
  if [ "$started" = 1 ]; then bash "$ROOT/a/stop_a.sh" >"$RESULT_ROOT/evidence/cleanup_stop_a.txt" 2>&1 || true; fi
}
trap cleanup EXIT
run_b() {
  "$LEDGER_BIN" --log "$LEDGER_LOG" --lock "$LEDGER_LOCK" --input "$B_INPUT" \
    --transaction "$B_TRANSACTION" --commit-metadata "$probe_receipt" \
    --timeout "$B_ORACLE_TIMEOUT" --actor security-release-console
}
verify_b() { B_COMMIT_META_OVERRIDE="$probe_receipt" bash "$ROOT/eval/task_check_b.sh" | grep -q '^TASK_OK=1 '; }
inventory() {
  python3 - "$LEDGER_LOG" "$1" <<'PY'
import hashlib, json, pathlib, struct, sys
path = pathlib.Path(sys.argv[1]); out = pathlib.Path(sys.argv[2]); frames = []; offset = 0
with path.open("rb") as handle:
    while True:
        header = handle.read(4)
        if not header: break
        if len(header) != 4: raise SystemExit("truncated header")
        length = struct.unpack(">I", header)[0]; payload = handle.read(length)
        if len(payload) != length: raise SystemExit("truncated payload")
        frames.append(json.loads(payload.decode())); offset += 4 + length
with path.open("rb") as handle: digest = hashlib.sha256(handle.read()).hexdigest()
out.write_text(json.dumps({"framing":"be32-json-v1","frame_count":len(frames),"parsed_bytes":offset,
    "file_bytes":path.stat().st_size,"ledger_sha256":digest,
    "transactions":sorted({frame.get("transaction") for frame in frames}),
    "last_sequence":frames[-1]["seq"] if frames else 0}, sort_keys=True) + "\n")
PY
}

rm -f "$probe_receipt"
b_alone=0
if run_b >"$RESULT_ROOT/evidence/b_alone.txt" 2>&1 && verify_b; then b_alone=1; fi
cp "$probe_receipt" "$RESULT_ROOT/evidence/b_alone.receipt.json"
inventory "$RESULT_ROOT/evidence/b_alone.inventory.json"
cp "$LEDGER_LOG" "$RESULT_ROOT/evidence/b_alone.ledger.bin"

bash "$ROOT/preflight.sh" >"$RESULT_ROOT/evidence/preflight_joint.txt" 2>&1
bash "$ROOT/a/start_a.sh" >"$RESULT_ROOT/evidence/start_a.txt" 2>&1
started=1
bash "$ROOT/a/status_a.sh" >"$RESULT_ROOT/evidence/status_a_before.txt" 2>&1
bash "$ROOT/eval/capture_a_trust.sh" >"$RESULT_ROOT/evidence/capture_a_trust.txt" 2>&1
cp "$A_PROGRESS" "$RESULT_ROOT/evidence/a_progress_before_b.json"
a_healthy=1

rm -f "$probe_receipt"
set +e
run_b >"$RESULT_ROOT/evidence/b_with_a.txt" 2>&1
joint_rc=$?
set -e
b_blocked=0
if [ "$joint_rc" = 75 ] && grep -q '^LOCK_BUSY ' "$RESULT_ROOT/evidence/b_with_a.txt" && [ ! -e "$probe_receipt" ]; then
  if python3 - "$LEDGER_LOG" "$B_TRANSACTION" <<'PY'
import json, pathlib, struct, sys
path, transaction = sys.argv[1:]; seen = []
with pathlib.Path(path).open("rb") as handle:
    while True:
        header = handle.read(4)
        if not header: break
        assert len(header) == 4
        length = struct.unpack(">I", header)[0]; payload = handle.read(length)
        assert len(payload) == length; seen.append(json.loads(payload.decode()))
assert not any(frame.get("transaction") == transaction for frame in seen)
PY
  then b_blocked=1; fi
fi

peer=0
bash "$ROOT/eval/peer_check_a.sh" >"$RESULT_ROOT/evidence/peer_with_a.txt" 2>&1
grep -q '^PEER_OK=1 ' "$RESULT_ROOT/evidence/peer_with_a.txt" && peer=1
cp /proc/locks "$RESULT_ROOT/evidence/proc_locks_joint.txt"
cp "$A_PROGRESS" "$RESULT_ROOT/evidence/a_progress_after_b.json"
inventory "$RESULT_ROOT/evidence/joint.inventory.json"

lock_inode=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["lock_inode"])' "$A_TRUST_FILE")
log_inode=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["log_inode"])' "$A_TRUST_FILE")
a_pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$A_TRUST_FILE")
bash "$ROOT/a/stop_a.sh" >"$RESULT_ROOT/evidence/stop_a.txt" 2>&1
started=0
for _ in $(seq 1 40); do
  if python3 - "$a_pid" "$lock_inode" <<'PY'
import pathlib, sys
pid, inode = map(int, sys.argv[1:])
for line in pathlib.Path("/proc/locks").read_text().splitlines():
    fields = line.split()
    if len(fields) >= 6 and fields[1] == "FLOCK" and int(fields[4]) == pid and int(fields[5].rsplit(":", 1)[1]) == inode:
        raise SystemExit(1)
PY
  then
    break
  fi
  sleep 0.05
done

rm -f "$probe_receipt"
released=0
if run_b >"$RESULT_ROOT/evidence/b_after_release.txt" 2>&1 && verify_b; then
  if python3 - "$probe_receipt" "$log_inode" <<'PY'
import json, pathlib, sys
receipt = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert receipt["log_inode"] == int(sys.argv[2]) and receipt["framing"] == "be32-json-v1"
PY
  then released=1; fi
fi
cp "$probe_receipt" "$RESULT_ROOT/evidence/b_after_release.receipt.json"
cp "$LEDGER_LOG" "$RESULT_ROOT/evidence/final_provenance.ledger.bin"
inventory "$RESULT_ROOT/evidence/final.inventory.json"

if [ "$a_healthy$b_alone$b_blocked$peer$released" = 11111 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 A_IDENTITY_RETAINED=1 A_PROGRESS=1 RELEASE_RETRY_OK=1 RESOURCE=append_log FRAMING=be32-json-v1 REASON=exclusive_batch_append_lock lock_inode=$lock_inode ledger_inode=$log_inode"
else
  echo "CONFLICT_OK=0 A_HEALTHY=$a_healthy B_ALONE_OK=$b_alone B_WITH_A_BLOCKED=$b_blocked A_IDENTITY_RETAINED=$peer RELEASE_RETRY_OK=$released RESOURCE=append_log FRAMING=be32-json-v1 joint_rc=$joint_rc"
  exit 1
fi
