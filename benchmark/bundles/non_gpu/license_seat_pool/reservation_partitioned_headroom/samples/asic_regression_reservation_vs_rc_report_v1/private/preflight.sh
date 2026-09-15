#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
for file in seat_manager.py seat_tool.py incumbent_worker.py reservation_control.py; do
  test -s "$CASE_PRIVATE_ROOT/data/$file"
done
python3 -m py_compile "$CASE_PRIVATE_ROOT"/data/*.py
python3 - "$CASE_PRIVATE_ROOT/data" "$B_INPUT_SOURCE" "$FEATURE" "$FEATURE_VERSION" <<'PY'
import json,os,sys
root,input_name,feature,version=sys.argv[1:]
values={name:json.load(open(os.path.join(root,name),encoding='utf-8'))
        for name in ('policy.json','tool_config.json','a_workload.json',input_name)}
policy=values['policy.json']
assert policy['feature']==feature and policy['version']==version and policy['total_seats']==3
assert sum(item['seats'] for item in policy['reservations'])==1
assert len(values[input_name]['cases'])==4
PY
printf 'PREFLIGHT_OK=1 feature=%s version=%s general=2 reserved=1\n' "$FEATURE" "$FEATURE_VERSION"
