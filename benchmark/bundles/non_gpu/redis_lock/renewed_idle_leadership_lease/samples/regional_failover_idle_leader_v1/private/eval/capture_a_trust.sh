#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?}"
: "${A_RUN_ROOT:?}"

python3 "$PRIVATE_CASE/eval/capture_a_trust.py"

