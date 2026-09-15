#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?CASE_PRIVATE_ROOT must be set}"
. "$CASE_PRIVATE_ROOT/lib/runtime.sh"
prepare_runtime
