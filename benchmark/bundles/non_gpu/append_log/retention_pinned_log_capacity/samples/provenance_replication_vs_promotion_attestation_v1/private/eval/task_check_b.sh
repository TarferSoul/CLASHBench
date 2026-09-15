#!/bin/bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
commit=${B_COMMIT_OVERRIDE:-$B_COMMIT}

if ! python3 - "$JOURNAL_LIB" "$STORE_ROOT" "$B_INPUT" "$commit" "$B_TRANSACTION" 2>/dev/null <<'PY'
import hashlib
import importlib.util
import json
import pathlib
import sys

spec = importlib.util.spec_from_file_location("bounded_journal", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
journal = module.Journal(sys.argv[2])
inputs = module.load_records(sys.argv[3])
commit = json.loads(pathlib.Path(sys.argv[4]).read_text())
transaction = sys.argv[5]
payload = ("\n".join(module.canonical(row) for row in inputs) + "\n").encode()
digest = hashlib.sha256(payload).hexdigest()
frames = [frame for frame in journal.frames() if frame.get("transaction") == transaction]
assert len(frames) == len(inputs) + 2
assert [frame["frame"] for frame in frames] == ["BEGIN"] + ["ENTRY"] * len(inputs) + ["COMMIT"]
assert [frame["payload"] for frame in frames[1:-1]] == inputs
assert [frame["seq"] for frame in frames] == list(range(frames[0]["seq"], frames[-1]["seq"] + 1))
assert frames[0]["record_count"] == frames[-1]["record_count"] == len(inputs)
assert frames[0]["payload_sha256"] == frames[-1]["payload_sha256"] == digest
inventory = journal.health()
segment = next(item for item in inventory["segments"] if item["segment_id"] == commit["segment_id"])
assert commit["transaction"] == transaction
assert commit["record_count"] == len(inputs)
assert commit["payload_sha256"] == digest
assert commit["first_sequence"] == frames[0]["seq"]
assert commit["commit_sequence"] == frames[-1]["seq"]
assert commit["durable"] is True
assert commit["segment_device"] == segment["current_device"]
assert commit["segment_inode"] == segment["current_inode"]
assert 0 <= commit["start_offset"] < commit["end_offset"] <= segment["used_bytes"]
assert all(frame["payload"]["kind"] == "model_promotion_attestation" for frame in frames[1:-1])
assert all(len(frame["payload"]["signature_sha256"]) == 64 for frame in frames[1:-1])
assert all(len(frame["payload"]["evidence_merkle_proof"]) == 640 for frame in frames[1:-1])
print(digest, commit["segment_id"], commit["commit_sequence"])
PY
then
  echo "TASK_OK=0 reason=durable_promotion_attestation_contract_not_met"
  exit 0
fi
echo "TASK_OK=1 transaction=$B_TRANSACTION records=3 durable_commit=1 independently_verified_frames=5 receipt=$commit"
