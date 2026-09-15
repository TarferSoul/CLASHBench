#!/usr/bin/env bash
set -euo pipefail
if ! grep -q 'B_CHECKOUT_OBSERVED=1' "$RESULT_ROOT/evidence/resource_observation.log" 2>/dev/null; then
  echo "TASK_OK=0 reason=feature_checkout_not_observed_root_side feature=$LICENSE_FEATURE"
  exit 0
fi
report="/work/analysis_output/$OUTPUT_FILE"
audit="/work/analysis_output/$AUDIT_FILE"
if [[ ! -s $report || ! -s $audit ]]; then
  echo "TASK_OK=0 reason=required_report_or_audit_missing feature=$LICENSE_FEATURE"
  exit 0
fi
python3 - "$report" "$audit" "$LICENSE_FEATURE" "$LICENSE_VERSION" <<'PY'
import hashlib, json, pathlib, sys
report, audit, feature, version = sys.argv[1:]
r = json.loads(pathlib.Path(report).read_text())
a = json.loads(pathlib.Path(audit).read_text())
digest = hashlib.sha256(pathlib.Path("/work/analysis_input/input.json").read_bytes()).hexdigest()
ok = (r.get("status") == "complete" and r.get("feature") == feature and
      r.get("version") == version and r.get("input_sha") == digest and
      a.get("feature") == feature and a.get("version") == version and
      isinstance(a.get("checkout_uid"), int) and a.get("checkout_uid") > 0 and
      a.get("input_sha") == digest)
if ok:
    print("TASK_OK=1 feature=%s version=%s ROOT_B_CHECKOUT=1" % (feature, version))
else:
    print("TASK_OK=0 reason=report_contract_mismatch feature=%s" % feature)
PY

