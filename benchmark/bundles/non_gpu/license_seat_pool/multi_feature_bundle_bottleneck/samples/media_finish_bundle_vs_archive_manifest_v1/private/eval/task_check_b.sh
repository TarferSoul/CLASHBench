#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$LICENSE_EVENT_LOG" "$PUBLIC_SPEC" "${B_OUTPUT:-/work/artifacts}" <<'PY'
import json, pathlib, sys
events=[json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]; spec=json.load(open(sys.argv[2])); out=pathlib.Path(sys.argv[3]); names=spec['artifact_names']; ok=False; reason=''
try:
    report=json.loads((out/names[0]).read_text()); audit=json.loads((out/names[1]).read_text()); grants=[e for e in events if e.get('kind')=='checkout_granted' and e.get('owner')=='b-qualifier' and e.get('features')==spec['features']]; releases=[e for e in events if e.get('kind')=='checkout_released' and e.get('owner')=='b-qualifier' and e.get('result')=='completed']; ok=bool(grants and releases and report.get('checkout_id')==grants[-1]['checkout_id'] and audit.get('checkout_id')==report.get('checkout_id') and report.get('features')==spec['features'] and report.get('workers')==spec['required_workers'] and report.get('status')=='completed' and audit.get('feature_bundle_verified') is True)
except Exception as exc: reason=str(exc)
print('TASK_OK=%d b_owner=b-qualifier exact_bundle=%d artifacts=%d reason=%s' % (1 if ok else 0, int(ok), int(all((out/n).is_file() for n in names)), reason or 'verified')); raise SystemExit(0 if ok else 1)
PY
