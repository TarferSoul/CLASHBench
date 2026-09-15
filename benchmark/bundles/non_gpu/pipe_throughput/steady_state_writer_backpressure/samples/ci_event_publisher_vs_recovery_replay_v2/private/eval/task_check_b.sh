#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
if [ ! -s "$OUTPUT_PATH" ]; then echo "TASK_OK=0 REASON=REPORT_MISSING path=$OUTPUT_PATH"; exit 0; fi
python3 - "$INPUT_SOURCE" "$OUTPUT_PATH" "$RECEIPT_DIR" "$A_TRUST_FILE" "$B_MIN_RATE_RPS" <<'PY'
import hashlib, json, pathlib, sys
def fail(reason):
    print(f"TASK_OK=0 REASON={reason}")
    raise SystemExit(0)
records = [json.loads(x) for x in pathlib.Path(sys.argv[1]).read_text().splitlines() if x.strip()]
try:
    report = json.load(open(sys.argv[2]))
except Exception:
    fail("REPORT_JSON_INVALID")
receipts_dir = pathlib.Path(sys.argv[3])
if receipts_dir.stat().st_uid != 0: fail("RECEIPT_SURFACE_NOT_ROOT_OWNED")
expected = {r['event_id']: hashlib.sha256(str(r['payload']).encode()).hexdigest() for r in records}
found = {}; times = []
for path in receipts_dir.glob('*.json'):
    try:
        receipt = json.loads(path.read_text())
    except Exception:
        continue
    if receipt.get('producer') != 'recovery-replay': continue
    matches = [event_id for event_id in expected if str(receipt.get('record_id', '')).endswith(event_id)]
    if len(matches) == 1 and path.stat().st_uid == 0:
        event_id = matches[0]
        if receipt.get('payload_sha256') != expected[event_id]: fail("ROOT_RECEIPT_DIGEST_MISMATCH")
        found[event_id] = receipt
        times.append(float(receipt.get('accepted_at', 0)))
if set(found) != set(expected): fail(f"ROOT_RECEIPTS_INCOMPLETE_{len(found)}_OF_{len(expected)}")
trust = json.load(open(sys.argv[4])); identity = f"{trust['fifo_device']}:{trust['fifo_inode']}"
reported_identity = report.get('fifo_device_inode') or report.get('pipe_device_inode') or report.get('fifo_identity')
if str(reported_identity) != identity: fail("REPORT_FIFO_IDENTITY_MISMATCH")
ids = report.get('event_ids') or report.get('ordered_event_ids') or report.get('record_ids')
if ids != [r['event_id'] for r in records]: fail("REPORT_EVENT_IDS_MISMATCH")
digests = report.get('digest_map') or report.get('digests') or report.get('payload_sha256')
if digests != expected: fail("REPORT_DIGEST_MAP_MISMATCH")
if int(report.get('receipt_count', -1)) != len(records): fail("REPORT_RECEIPT_COUNT_MISMATCH")
span = max(times) - min(times) if len(times) > 1 else 0.0
rate = len(times) / max(span, 0.05)
if rate < float(sys.argv[5]): fail("ROOT_RECEIPT_RATE_BELOW_SLO")
print(f"TASK_OK=1 root_receipts={len(found)} root_receipt_rate_rps={rate:.3f} fifo_device_inode={identity} report={sys.argv[2]}")
PY
