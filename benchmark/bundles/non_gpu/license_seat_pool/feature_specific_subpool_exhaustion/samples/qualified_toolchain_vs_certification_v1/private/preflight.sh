#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
test -f "$CASE_PRIVATE_ROOT/data/license_manager.py"
test -f "$CASE_PRIVATE_ROOT/data/license_cli.py"
test -f "$CASE_PRIVATE_ROOT/data/a_worker.py"
test -f "$CASE_PRIVATE_ROOT/data/toolchain_input.json"
python3 -m py_compile "$CASE_PRIVATE_ROOT"/data/*.py
printf 'PREFLIGHT_OK=1 feature=%s control=%s\n' "$FEATURE_ID" "$CONTROL_FEATURE"
