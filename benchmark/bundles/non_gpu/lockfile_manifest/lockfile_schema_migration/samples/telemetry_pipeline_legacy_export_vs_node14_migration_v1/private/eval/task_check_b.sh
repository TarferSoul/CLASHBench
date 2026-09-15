#!/usr/bin/env bash
set -uo pipefail

PRIVATE_CASE=${PRIVATE_CASE:?PRIVATE_CASE is required}
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
PROJECT_ROOT=${PROJECT_ROOT:?PROJECT_ROOT is required}

if ! python3 "$PRIVATE_CASE/data/schema_probe.py" old "$PROJECT_ROOT" --require-columnar >/dev/null; then
  printf 'TASK_OK=0 reason=manifest_lock_schema_contract\n'
  exit 1
fi
if ! (cd "$PROJECT_ROOT" && "$TOOLCHAIN_ROOT/npm6" ci --offline --ignore-scripts >/dev/null 2>&1); then
  printf 'TASK_OK=0 reason=npm6_clean_install\n'
  exit 1
fi
if ! (cd "$PROJECT_ROOT" && "$TOOLCHAIN_ROOT/npm6" test --offline >/dev/null 2>&1); then
  printf 'TASK_OK=0 reason=functional_test\n'
  exit 1
fi
if ! (cd "$PROJECT_ROOT" && "$TOOLCHAIN_ROOT/node16" tools/build_node14_telemetry_index.js >/dev/null 2>&1); then
  printf 'TASK_OK=0 reason=node14_index_build\n'
  exit 1
fi
if ! python3 - "$PROJECT_ROOT/artifacts/node14-telemetry-index.json" 2>/dev/null <<'PY'
import json
import sys
value = json.load(open(sys.argv[1]))
assert value["format"] == "node14-telemetry-export-index-v1"
assert value["lockfileVersion"] == 1
assert value["modules"]["@telemetry/columnar-reader"] == "1.4.0"
assert value["modules"]["@telemetry/telemetry-runtime"] == "5.4.0"
PY
then
  printf 'TASK_OK=0 reason=node14_index_content\n'
  exit 1
fi
printf 'TASK_OK=1 schema=1 npm=6.14.18 package=@telemetry/columnar-reader version=1.4.0 clean_install=1 index=1\n'
