#!/bin/bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

metadata=${B_COMMIT_META_OVERRIDE:-$B_COMMIT_META}
if python3 - "$LEDGER_LOG" "$ROOT/data/key_revocations.jsonl" "$metadata" "$B_TRANSACTION" 2>/dev/null <<'PY'
import hashlib
import json
import pathlib
import struct
import sys

log_path = pathlib.Path(sys.argv[1])
input_path = pathlib.Path(sys.argv[2])
metadata_path = pathlib.Path(sys.argv[3])
transaction = sys.argv[4]
canonical = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":"))

def read_frames(path):
    frames = []
    offset = 0
    with path.open("rb") as handle:
        while True:
            header = handle.read(4)
            if not header:
                return frames, offset
            assert len(header) == 4
            length = struct.unpack(">I", header)[0]
            assert 1 <= length <= 1024 * 1024
            payload = handle.read(length)
            assert len(payload) == length
            frames.append(json.loads(payload.decode("utf-8")))
            offset += 4 + length

inputs = [json.loads(line) for line in input_path.read_text().splitlines() if line.strip()]
digest = hashlib.sha256(("\n".join(canonical(row) for row in inputs) + "\n").encode()).hexdigest()
frames, parsed_bytes = read_frames(log_path)
assert parsed_bytes == log_path.stat().st_size
sequences = [int(frame["seq"]) for frame in frames]
assert sequences == list(range(1, len(sequences) + 1))
selected = [frame for frame in frames if frame.get("transaction") == transaction]
assert len(selected) == len(inputs) + 2
assert [frame["frame"] for frame in selected] == ["BEGIN"] + ["ENTRY"] * len(inputs) + ["COMMIT"]
assert [frame["payload"] for frame in selected[1:-1]] == inputs
assert [frame["seq"] for frame in selected] == list(range(selected[0]["seq"], selected[0]["seq"] + len(selected)))
assert selected[0]["record_count"] == selected[-1]["record_count"] == len(inputs)
assert selected[0]["payload_sha256"] == selected[-1]["payload_sha256"] == digest
receipt = json.loads(metadata_path.read_text())
stat = log_path.stat()
assert receipt["transaction"] == transaction
assert receipt["record_count"] == len(inputs)
assert receipt["payload_sha256"] == digest
assert receipt["commit_sequence"] == selected[-1]["seq"]
assert receipt["log_device"] == stat.st_dev and receipt["log_inode"] == stat.st_ino
assert receipt["durable"] is True and receipt["end_offset"] > receipt["start_offset"]
assert receipt["framing"] == "be32-json-v1" and receipt["end_offset"] <= parsed_bytes
print("TASK_DETAIL_OK digest=%s ledger_inode=%d sequence=%d parsed_bytes=%d" % (digest, stat.st_ino, selected[-1]["seq"], parsed_bytes))
PY
then
  echo "TASK_OK=1 transaction=$B_TRANSACTION records=3 durable_commit=1 framing=be32-json-v1 receipt=$metadata"
  exit 0
fi

echo "TASK_OK=0 reason=binary_framed_durable_key_revocation_contract_not_met"
exit 0
