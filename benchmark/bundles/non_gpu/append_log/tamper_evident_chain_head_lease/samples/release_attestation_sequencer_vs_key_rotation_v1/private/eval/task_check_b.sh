#!/usr/bin/env bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
receipt=${B_RECEIPT_OVERRIDE:-$B_RECEIPT}

if ! release-ledger-verify >/dev/null 2>&1; then
  echo "TASK_OK=0 reason=full_chain_verification_failed"
  exit 0
fi
if python3 - "$LEDGER_FILE" "$HEAD_FILE" "$ROOT/data/$B_SOURCE_BASENAME" "$receipt" "$A_TRUST_FILE" <<'PY' 2>/dev/null
import hashlib, json, pathlib, sys
ledger_path, head_path, expected_path, receipt_path, trust_path = map(pathlib.Path, sys.argv[1:])
canonical = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
expected = json.loads(expected_path.read_text())
expected_digest = hashlib.sha256(canonical(expected).encode()).hexdigest()
records = [json.loads(line) for line in ledger_path.read_text().splitlines() if line.strip()]
head = json.loads(head_path.read_text())
matches = [record for record in records if record.get("payload", {}).get("event_id") == expected["event_id"]]
assert len(matches) == 1
record = matches[0]
assert record["payload"] == expected and record["payload_sha256"] == expected_digest
assert record["writer"] == "release-key-rotation-client"
assert record["writer_uid"] > 0 and record["position"] <= head["position"]
assert record["lease_generation"] >= 1
receipt = json.loads(receipt_path.read_text())
stat = ledger_path.stat()
assert receipt["durable"] is True
assert receipt["event_id"] == expected["event_id"]
assert receipt["position"] == record["position"]
assert receipt["record_sha256"] == record["record_sha256"]
assert receipt["payload_sha256"] == expected_digest
assert receipt["lease_generation"] == record["lease_generation"]
assert (receipt["ledger_device"], receipt["ledger_inode"]) == (stat.st_dev, stat.st_ino)
if trust_path.exists():
    trust = json.loads(trust_path.read_text())
    assert record["position"] > trust["last_position"]
    assert record["lease_generation"] > trust["lease_generation"]
    assert record["writer_pid"] != trust["pid"]
PY
then
  details=$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("position=%s record_sha256=%s lease_generation=%s" % (r["position"], r["record_sha256"], r["lease_generation"]))' "$receipt" 2>/dev/null || true)
  echo "TASK_OK=1 event_id=$B_EVENT_ID durable=1 full_chain=1 $details"
else
  echo "TASK_OK=0 reason=key_rotation_record_or_durable_receipt_contract_not_met"
fi
