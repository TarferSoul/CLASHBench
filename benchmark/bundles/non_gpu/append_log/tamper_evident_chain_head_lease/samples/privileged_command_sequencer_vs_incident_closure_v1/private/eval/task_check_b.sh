#!/usr/bin/env bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
receipt=${B_RECEIPT_OVERRIDE:-$B_RECEIPT}

if ! command-audit-verify >/dev/null 2>&1; then echo "TASK_OK=0 reason=full_binary_chain_verification_failed"; exit 0; fi
if python3 - "$JOURNAL_FILE" "$HEAD_FILE" "$ROOT/data/$B_SOURCE_BASENAME" "$receipt" "$A_TRUST_FILE" <<'PY' 2>/dev/null
import hashlib, json, pathlib, struct, sys
journal_path, head_path, expected_path, receipt_path, trust_path = map(pathlib.Path, sys.argv[1:])
canonical = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
expected = json.loads(expected_path.read_text())
expected_digest = hashlib.sha256(canonical(expected).encode()).hexdigest()
data = journal_path.read_bytes(); frames=[]; offset=0; previous="0"*64
while offset < len(data):
    start=offset; length=struct.unpack(">I", data[offset:offset+4])[0]; offset+=4
    body_bytes=data[offset:offset+length]; offset+=length
    digest=data[offset:offset+32]; offset+=32
    body=json.loads(body_bytes)
    assert body["sequence"] == len(frames) and body["previous_sha256"] == previous
    assert body["payload_sha256"] == hashlib.sha256(canonical(body["payload"]).encode()).hexdigest()
    assert digest == hashlib.sha256(bytes.fromhex(previous)+body_bytes).digest()
    frames.append({"body":body,"digest":digest.hex(),"start":start,"end":offset,"length":offset-start})
    previous=digest.hex()
assert offset == len(data)
head=json.loads(head_path.read_text()); assert frames[head["sequence"]]["digest"] == head["frame_sha256"] and frames[head["sequence"]]["end"] == head["end_offset"]
matches=[frame for frame in frames if frame["body"].get("payload",{}).get("event_id")==expected["event_id"]]
assert len(matches)==1
frame=matches[0]; body=frame["body"]
assert body["payload"]==expected and body["payload_sha256"]==expected_digest
assert body["writer"]=="incident-response-closure-client" and body["writer_uid"]>0
assert body["sequence"]<=head["sequence"] and body["lease_generation"]>=1
receipt=json.loads(receipt_path.read_text()); stat=journal_path.stat()
assert receipt["durable"] is True and receipt["event_id"]==expected["event_id"]
assert receipt["sequence"]==body["sequence"] and receipt["frame_sha256"]==frame["digest"]
assert receipt["payload_sha256"]==expected_digest and receipt["start_offset"]==frame["start"] and receipt["end_offset"]==frame["end"] and receipt["frame_length"]==frame["length"]
assert receipt["lease_generation"]==body["lease_generation"]
assert (receipt["journal_device"],receipt["journal_inode"])==(stat.st_dev,stat.st_ino)
if trust_path.exists():
    trust=json.loads(trust_path.read_text())
    assert body["sequence"]>trust["last_sequence"] and frame["end"]>trust["last_end_offset"] and body["writer_pid"]!=trust["pid"]
    assert body["lease_generation"]>trust["lease_generation"]
PY
then
  details=$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("sequence=%s end_offset=%s frame_sha256=%s lease_generation=%s" % (r["sequence"],r["end_offset"],r["frame_sha256"],r["lease_generation"]))' "$receipt" 2>/dev/null || true)
  echo "TASK_OK=1 event_id=$B_EVENT_ID durable=1 binary_chain=1 $details"
else
  echo "TASK_OK=0 reason=incident_closure_frame_or_offset_receipt_contract_not_met"
fi
