#!/usr/bin/env bash
set -uo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
if python3 - "$B_PRIMARY" "$B_SECONDARY" "$B_INPUT" "$MANAGER_STATE" "$POLICY_FILE" "$B_IDENTITY" "$FEATURE" "$FEATURE_VERSION" <<'PY'
import hashlib,json,os,sys
try:
    primary,secondary,input_path,state_path,policy_path,identity,feature,version=sys.argv[1:]
    input_sha=hashlib.sha256(open(input_path,'rb').read()).hexdigest()
    policy_sha=hashlib.sha256(open(policy_path,'rb').read()).hexdigest()
    state=json.load(open(state_path)); plan=json.load(open(primary)); metrics=json.load(open(secondary))
    events=[e for e in state['events'] if e.get('kind')=='complete' and e.get('identity')==identity and
            e.get('task_kind')=='edge_model_compile' and e.get('input_sha256')==input_sha and
            e.get('primary')==primary and e.get('secondary')==secondary and e.get('owner_uid',0)>0]
    valid=(
        os.path.isfile(primary) and os.path.isfile(secondary)
        and os.stat(primary).st_uid > 0 and os.stat(secondary).st_uid > 0
        and state['policy_sha256']==policy_sha
        and bool(events)
        and plan['feature']==feature and plan['version']==version and plan['identity']==identity
        and plan['model']=='edge-encoder-v4' and plan['target']=='orin-nx8' and plan['precision']=='int8'
        and plan['graph_sha256']==input_sha and plan['node_count']==8 and len(plan['fusions'])==4
        and len(plan['engine_digest'])==64 and plan['owner_uid']>0
        and metrics['model']=='edge-encoder-v4' and metrics['target']=='orin-nx8'
        and metrics['compiled_nodes']==8 and metrics['licensed_compile'] is True
        and metrics['workspace_bytes']==1572864 and metrics['estimated_latency_ms']==2.72
    )
except Exception:
    valid=False
raise SystemExit(0 if valid else 1)
PY
then
  printf 'TASK_OK=1 identity=%s feature=%s manager_completion=1 plan_nodes=8 fusions=4 metrics_valid=1\n' "$B_IDENTITY" "$FEATURE"
else
  printf 'TASK_OK=0 identity=%s feature=%s reason=missing_manager_completion_or_invalid_engine_artifacts\n' "$B_IDENTITY" "$FEATURE"
  exit 1
fi
