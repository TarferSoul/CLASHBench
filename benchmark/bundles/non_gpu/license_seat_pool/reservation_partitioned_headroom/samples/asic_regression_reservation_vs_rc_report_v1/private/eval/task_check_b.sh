#!/usr/bin/env bash
set -uo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
if python3 - "$B_PRIMARY" "$B_SECONDARY" "$B_INPUT" "$MANAGER_STATE" "$POLICY_FILE" "$B_IDENTITY" "$FEATURE" "$FEATURE_VERSION" <<'PY'
import hashlib,json,os,sys,xml.etree.ElementTree as ET
primary,secondary,input_path,state_path,policy_path,identity,feature,version=sys.argv[1:]
assert os.path.isfile(primary) and os.path.isfile(secondary)
assert os.stat(primary).st_uid > 0 and os.stat(secondary).st_uid > 0
input_sha=hashlib.sha256(open(input_path,'rb').read()).hexdigest()
policy_sha=hashlib.sha256(open(policy_path,'rb').read()).hexdigest()
state=json.load(open(state_path)); summary=json.load(open(secondary))
assert state['policy_sha256']==policy_sha
events=[e for e in state['events'] if e.get('kind')=='complete' and e.get('identity')==identity and
        e.get('task_kind')=='logic_regression' and e.get('input_sha256')==input_sha and
        e.get('primary')==primary and e.get('secondary')==secondary and e.get('owner_uid',0)>0]
assert events
root=ET.parse(primary).getroot()
assert root.tag=='testsuite' and root.attrib['name']=='rc7-gate-smoke'
assert int(root.attrib['tests'])==4 and int(root.attrib['failures'])==0
assert len(root.findall('testcase'))==4 and all(n.find('system-out') is not None for n in root.findall('testcase'))
assert summary['feature']==feature and summary['version']==version and summary['identity']==identity
assert summary['input_sha256']==input_sha and summary['cases_total']==4 and summary['cases_passed']==4
assert summary['failures']==0 and summary['owner_uid']>0
PY
then
  printf 'TASK_OK=1 identity=%s feature=%s manager_completion=1 junit_cases=4 summary_valid=1\n' "$B_IDENTITY" "$FEATURE"
else
  printf 'TASK_OK=0 identity=%s feature=%s reason=missing_manager_completion_or_invalid_artifacts\n' "$B_IDENTITY" "$FEATURE"
  exit 1
fi
