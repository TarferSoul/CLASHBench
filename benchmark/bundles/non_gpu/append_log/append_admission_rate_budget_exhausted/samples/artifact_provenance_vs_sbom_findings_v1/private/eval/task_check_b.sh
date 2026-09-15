#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
components=${B_COMPONENTS_OVERRIDE:-/work/inputs/components.json}; advisories=${B_ADVISORIES_OVERRIDE:-/work/inputs/advisories.json}; findings=${B_FINDINGS_OVERRIDE:-$B_FINDINGS}; receipts=${B_RECEIPTS_OVERRIDE:-$B_RECEIPTS}; summary=${B_SUMMARY_OVERRIDE:-$B_SUMMARY}; transaction=${B_TRANSACTION_OVERRIDE:-$B_TRANSACTION}
python3 - "$components" "$advisories" "$findings" "$receipts" "$summary" "$COLLECTOR_LOG" "$B_TOTAL_RECORDS" "$B_MIN_EPS" "$B_OWNER" "$transaction" <<'PY'
import hashlib,json,pathlib,sys
components_path,advisories_path,findings_path,receipts_path,summary_path,log_path,total,min_eps,owner,transaction=sys.argv[1:];total=int(total);min_eps=float(min_eps);reasons=[]
def js(path,label):
    try:return json.loads(pathlib.Path(path).read_text())
    except Exception:reasons.append("invalid_"+label);return {}
def jl(path,label):
    try:return [json.loads(line) for line in pathlib.Path(path).read_text().splitlines() if line.strip()]
    except Exception:reasons.append("invalid_"+label);return []
components=js(components_path,"components");advisories=js(advisories_path,"advisories");submitted=jl(findings_path,"findings");receipts=jl(receipts_path,"receipts");summary=js(summary_path,"report");frames=jl(log_path,"collector_log")
by_purl={}
for advisory in advisories.get("advisories",[]):by_purl.setdefault(advisory.get("purl"),[]).append(advisory)
expected=[]
for component in components.get("components",[]):
    for advisory in sorted(by_purl.get(component.get("purl"),[]),key=lambda item:item.get("advisory_id","")):
        source=f"{component['component_id']}|{advisory['advisory_id']}";expected.append({"finding_id":"sbom-"+hashlib.sha256(source.encode()).hexdigest()[:20],"component_id":component["component_id"],"name":component["name"],"version":component["version"],"purl":component["purl"],"artifact":component["artifact"],"advisory_id":advisory["advisory_id"],"severity":advisory["severity"],"fixed_version":advisory["fixed_version"],"review_action":"upgrade" if advisory["severity"] in ("critical","high") else "track"})
expected_by_id={row["finding_id"]:row for row in expected}
if len(expected_by_id)!=total:reasons.append("independent_expected_count")
submitted_by_id={str(row.get("finding_id")):row for row in submitted}
if submitted_by_id!=expected_by_id:reasons.append("computed_findings_mismatch")
if summary.get("component_count")!=len(components.get("components",[])):reasons.append("report_component_count")
if summary.get("expected_findings")!=total or summary.get("durable_findings")!=total:reasons.append("report_durable_counts")
if summary.get("missing_finding_ids") not in ([],None):reasons.append("report_missing_ids")
try:observed=float(summary.get("observed_ingest_eps"))
except Exception:observed=-1;reasons.append("report_observed_eps")
if observed<min_eps:reasons.append("throughput_below_minimum")
receipt_by_id={str(row.get("finding_id")):row for row in receipts}
if set(receipt_by_id)!=set(expected_by_id):reasons.append("receipt_id_set")
if any(row.get("sequence") is None or row.get("durable_offset") is None for row in receipt_by_id.values()):reasons.append("receipt_offsets_missing")
durable=[row for row in frames if row.get("owner")==owner and row.get("transaction")==transaction and row.get("event_type")=="sbom_review_finding"];durable_by_id={str(row.get("event_id")):row for row in durable}
if set(durable_by_id)!=set(expected_by_id):reasons.append("independent_durable_id_set")
for finding_id,row in expected_by_id.items():
    if finding_id in durable_by_id and durable_by_id[finding_id].get("payload")!=row:reasons.append("durable_payload_mismatch");break
sequences=[row.get("sequence") for row in durable_by_id.values()]
if any(not isinstance(value,int) for value in sequences) or len(set(sequences))!=total:reasons.append("durable_sequences_invalid")
ok=not reasons;print(f"TASK_OK={int(ok)} components={len(components.get('components',[]))} expected={len(expected_by_id)} submitted={len(submitted_by_id)} durable_report={summary.get('durable_findings')} independent_durable={len(durable_by_id)} observed_eps={observed:.3f} reasons={','.join(reasons) if reasons else 'none'}");raise SystemExit(0 if ok else 1)
PY
