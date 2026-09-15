#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
command -v python3 >/dev/null; command -v git >/dev/null
for path in "$SCHEMA_REL" "$TEMPLATE_REL" "$GENERATOR_REL" "$TARGET_REL"; do test -r "$CANONICAL_REPO/$path"; done
python3 -m py_compile "$CANONICAL_REPO/$GENERATOR_REL" "$CANONICAL_REPO/$TARGET_REL"
(cd "$CANONICAL_REPO" && PYTHONPATH=src python3 -m unittest -q tests.test_event_model)
echo "PREFLIGHT_OK=1 target=$TARGET_REL"
