#!/usr/bin/env bash
set -euo pipefail
root=${CASE_PRIVATE_ROOT:?}
. "$root/fixture.env"
python3 "$root/eval/check_task.py" "$SERVICE_AUDIT"
