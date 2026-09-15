#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
test -d "$CANONICAL_REPO/.git"
test -s "$BASE_OID_FILE"
test "$(git -C "$CANONICAL_REPO" symbolic-ref --short HEAD)" = main
test "$(git -C "$CANONICAL_REPO" rev-parse "$TARGET_BRANCH")" = "$(cat "$BASE_OID_FILE")"
python3 -m py_compile "$CASE_PRIVATE_ROOT/data/seed_repository.py" \
  "$CASE_PRIVATE_ROOT/data/qualification_worker.py" \
  "$CASE_PRIVATE_ROOT/data/apply_b.py" \
  "$CASE_PRIVATE_ROOT/data/lease_damage_probes.py"
(cd "$CANONICAL_REPO" && python3 -m unittest discover -s tests -q && python3 tools/build_sdist.py --check)
printf 'PREFLIGHT_OK=1 sample=%s\n' "$SAMPLE_ID"
