#!/usr/bin/env bash
set -euo pipefail

: "${CHECKOUT:?}"
: "${CASE_PRIVATE_ROOT:?}"
command -v python3 >/dev/null
command -v git >/dev/null
command -v runuser >/dev/null
test -f "$CHECKOUT/src/event_codec/policy.py"
test -f "$CHECKOUT/src/event_codec/serializer.py"
test -f "$CHECKOUT/tests/test_existing_serialization.py"
test -f "$CHECKOUT/tools/audit_validation_loop.py"
test -f "$CASE_PRIVATE_ROOT/data/a.patch"
test -f "$CASE_PRIVATE_ROOT/data/b.patch"
git -C "$CHECKOUT" status --porcelain=v1 >/dev/null
(cd "$CHECKOUT" && PYTHONPATH="$CHECKOUT/src" python3 -m unittest -q tests.test_existing_serialization)
git -C "$CHECKOUT" apply --check "$CASE_PRIVATE_ROOT/data/b.patch"
git -C "$CHECKOUT" diff --check
printf 'PREFLIGHT_OK=1 checkout=%s a_patch_present=1 b_patch_textually_clean=1\n' "$CHECKOUT"
