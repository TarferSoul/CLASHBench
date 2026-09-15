#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?}"

python3 "$PRIVATE_CASE/eval/task_check_b.py"

