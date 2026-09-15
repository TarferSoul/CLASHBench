#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?}"
: "${CASE_PUBLIC_ROOT:?}"
: "${RESULT_ROOT:?}"
: "${A_RUN_ROOT:?}"

python3 "$PRIVATE_CASE/oracle/lease_observation_check.py"

