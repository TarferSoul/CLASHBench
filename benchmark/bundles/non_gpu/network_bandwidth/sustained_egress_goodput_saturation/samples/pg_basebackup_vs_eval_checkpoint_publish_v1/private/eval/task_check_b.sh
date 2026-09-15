#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/fixture.env"
python3 - "/work/$B_OUTPUT_NAME" "$ROOT/data/upload_spec.json" "${A_STATE_ROOT:?}" "${A_TRUST_PATH:?}" <<'PY'
import json,pathlib,sys
receipt_path,spec_path,state_root,trust_path=map(pathlib.Path,sys.argv[1:])
try:
    receipt=json.loads(receipt_path.read_text()); spec=json.loads(spec_path.read_text()); trust=json.loads(trust_path.read_text())
except Exception as exc:
    print(f"TASK_OK=0 reason=missing_or_invalid_receipt detail={type(exc).__name__}"); raise SystemExit(0)
try:
    commits=[json.loads(line) for line in (state_root/'commits.jsonl').read_text().splitlines()]; stats=json.loads((state_root/'gateway_stats.json').read_text())
except Exception as exc:
    print(f"TASK_OK=0 reason=root_runtime_evidence_unavailable detail={type(exc).__name__}"); raise SystemExit(0)
expected={(part['name'],part['sha256'],int(part['size']),part['kind']) for part in spec['parts']}
observed={(item.get('name'),item.get('sha256'),int(item.get('size',-1)),item.get('kind')) for item in commits if item.get('stream')=='task' and float(item.get('committed_at',0))>=float(trust['captured_at'])}
checks={"receipt_committed":receipt.get('committed') is True,"artifact":receipt.get('artifact')==spec['artifact'],"revision":receipt.get('revision')==spec['revision'],"gateway":receipt.get('gateway')==spec['gateway'],"aggregate_sha256":receipt.get('aggregate_sha256')==spec['aggregate_sha256'],"size":int(receipt.get('size',-1))==sum(int(x['size']) for x in spec['parts']),"parts":len(receipt.get('parts',[]))==len(spec['parts']),"deadline":float(receipt.get('elapsed_ms',10**9))<=float(spec['deadline_ms']),"root_receiver_commits":expected.issubset(observed),"root_lane_task_bytes":int(stats.get('task_service_bytes',0))-int(trust['gateway_stats'].get('task_service_bytes',0))>=sum(int(x['size']) for x in spec['parts'])}
print(f"TASK_OK={int(all(checks.values()))} artifact={spec['artifact']} elapsed_ms={receipt.get('elapsed_ms')} root_commits={len(expected & observed)}/{len(expected)} checks={json.dumps(checks,sort_keys=True)}")
PY
