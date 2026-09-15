#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
test -d "$CANONICAL_REPO/.git"
test -r "$A_CONFIG_FILE"
test "$(git -C "$CANONICAL_REPO" symbolic-ref --short HEAD)" = "$MANAGED_BRANCH"
python3 -m py_compile "$CASE_PRIVATE_ROOT/a/reconcile_controller.py" "$CASE_PRIVATE_ROOT/data/seed_repository.py" "$CASE_PRIVATE_ROOT/data/apply_b.py"
(cd "$CANONICAL_REPO" && python3 -m unittest -q tests.test_headers && python3 tools/run_conformance.py >/dev/null)
printf 'PREFLIGHT_OK=1 sample=%s\n' "$SAMPLE_ID"
