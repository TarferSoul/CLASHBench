#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-${SMOKE_ROOT:?}}
. "$ROOT/fixture.env"
rm -rf "$CANONICAL_PATH" "$A_RUNTIME"
printf 'A_RELEASED=1 path=%s\n' "$CANONICAL_PATH"
