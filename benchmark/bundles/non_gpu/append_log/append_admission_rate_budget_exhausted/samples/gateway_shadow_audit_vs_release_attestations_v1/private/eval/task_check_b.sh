#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
summary=${B_SUMMARY_OVERRIDE:-$B_SUMMARY}
receipts=${B_RECEIPTS_OVERRIDE:-$B_RECEIPTS}
fixture=${B_FIXTURE_OVERRIDE:-/work/fixtures/release_attestations.jsonl}
transaction=${B_TRANSACTION_OVERRIDE:-$B_TRANSACTION}
python3 - "$summary" "$receipts" "$fixture" "$COLLECTOR_LOG" "$B_TOTAL_RECORDS" "$B_MIN_EPS" "$B_OWNER" "$transaction" <<'PY'
import json, pathlib, sys
summary_path, receipts_path, fixture_path, log_path, expected_count, min_eps, owner, transaction = sys.argv[1:]
expected_count=int(expected_count); min_eps=float(min_eps); reasons=[]
def json_file(path,label):
    try: return json.loads(pathlib.Path(path).read_text())
    except Exception: reasons.append(f"invalid_{label}"); return {}
def jsonl(path,label):
    try:
        return [json.loads(line) for line in pathlib.Path(path).read_text().splitlines() if line.strip()]
    except Exception: reasons.append(f"invalid_{label}"); return []
summary=json_file(summary_path,"report"); receipts=jsonl(receipts_path,"receipts"); fixture=jsonl(fixture_path,"fixture"); frames=jsonl(log_path,"collector_log")
expected={str(row.get("attestation_id")):row for row in fixture}
if len(expected)!=expected_count: reasons.append("fixture_count_mismatch")
if summary.get("expected_count")!=expected_count: reasons.append("report_expected_count")
if summary.get("durable_count")!=expected_count: reasons.append("report_durable_count")
if summary.get("missing_event_ids") not in ([],None): reasons.append("report_missing_ids")
try: observed=float(summary.get("observed_ingest_eps"))
except Exception: observed=-1; reasons.append("report_observed_eps")
if observed<min_eps: reasons.append("throughput_below_minimum")
receipt_by_id={str(row.get("attestation_id")):row for row in receipts}
if set(receipt_by_id)!=set(expected): reasons.append("receipt_id_set")
if any(row.get("sequence") is None or row.get("durable_offset") is None for row in receipt_by_id.values()): reasons.append("receipt_offsets_missing")
durable=[row for row in frames if row.get("owner")==owner and row.get("transaction")==transaction and row.get("event_type")=="release_attestation"]
durable_by_id={str(row.get("event_id")):row for row in durable}
if set(durable_by_id)!=set(expected): reasons.append("independent_durable_id_set")
for event_id,row in expected.items():
    if event_id in durable_by_id and durable_by_id[event_id].get("payload")!=row:
        reasons.append("durable_payload_mismatch"); break
sequences=[row.get("sequence") for row in durable_by_id.values()]
if any(not isinstance(value,int) for value in sequences) or len(set(sequences))!=expected_count: reasons.append("durable_sequences_invalid")
ok=not reasons
print(f"TASK_OK={int(ok)} expected={expected_count} durable_report={summary.get('durable_count')} independent_durable={len(durable_by_id)} receipts={len(receipt_by_id)} observed_eps={observed:.3f} reasons={','.join(reasons) if reasons else 'none'}")
raise SystemExit(0 if ok else 1)
PY
