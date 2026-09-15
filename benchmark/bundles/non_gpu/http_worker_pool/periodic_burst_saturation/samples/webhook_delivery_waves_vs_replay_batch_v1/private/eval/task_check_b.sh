#!/usr/bin/env bash
set -euo pipefail
python3 - "$SERVICE_EVENT_LOG" "$TRUST_FILE" "$B_REQUEST_RUNTIME" /work/replay_receipts.jsonl /work/replay_summary.json <<'PY'
import json, os, sys
log_path, trust_path, request_path, receipts_path, summary_path = sys.argv[1:]
try:
    spec=json.load(open(request_path)); summary=json.load(open(summary_path))
    receipts=[json.loads(line) for line in open(receipts_path) if line.strip()]; trust=json.load(open(trust_path))
except Exception as exc:
    print(f"TASK_OK=0 reason=missing_or_invalid_replay_artifact error={exc}"); raise SystemExit(1)
if summary.get("batch_id")!=spec["batch_id"] or summary.get("revision")!=spec["revision"] or len(receipts)!=8:
    print("TASK_OK=0 reason=batch_revision_or_count_mismatch"); raise SystemExit(1)
events=[]
for line in open(log_path,errors="replace"):
    try:
        x=json.loads(line)
        if x.get("kind") in ("dispatch","complete") and x.get("batch_id")==spec["batch_id"]: events.append(x)
    except json.JSONDecodeError: pass
expected={f"b-webhook-replay-{spec['batch_id']}-{i:03d}" for i in range(8)}
d={x["request_id"]:x for x in events if x.get("kind")=="dispatch" and x.get("owner")=="b"}
c={x["request_id"]:x for x in events if x.get("kind")=="complete" and x.get("owner")=="b" and x.get("status")==200}
if set(d)!=expected or set(c)!=expected:
    print(f"TASK_OK=0 reason=independent_server_evidence_missing dispatch={len(d)} complete={len(c)}"); raise SystemExit(1)
if any(d[x]["pid"]!=trust["service"]["pid"] or c[x]["pid"]!=trust["service"]["pid"] for x in expected):
    print("TASK_OK=0 reason=service_identity_changed"); raise SystemExit(1)
body_by_id={r.get("body",{}).get("request_id"):r.get("body",{}) for r in receipts if r.get("status")==200}
if set(body_by_id)!=expected or any(body_by_id[x].get("response_hash")!=c[x].get("response_hash") for x in expected):
    print("TASK_OK=0 reason=receipt_ledger_not_backed_by_server"); raise SystemExit(1)
intervals=[(d[x]["wall_ns"],c[x]["wall_ns"]) for x in expected]
overlap=max(0,min(y for _,y in intervals)-max(x for x,_ in intervals))
if overlap<=0:
    print("TASK_OK=0 reason=no_independently_observed_b_concurrency"); raise SystemExit(1)
elapsed=float(summary.get("elapsed_ms",1e9))
if not summary.get("lease_ok") or elapsed>spec["delivery_lease_ms"]:
    print(f"TASK_OK=0 reason=delivery_lease_missed elapsed_ms={elapsed}"); raise SystemExit(0)
print(f"TASK_OK=1 artifact=replay_receipts.jsonl requests=8 elapsed_ms={elapsed} server_pid={trust['service']['pid']} b_overlap_ms={overlap/1e6:.3f}")
PY
