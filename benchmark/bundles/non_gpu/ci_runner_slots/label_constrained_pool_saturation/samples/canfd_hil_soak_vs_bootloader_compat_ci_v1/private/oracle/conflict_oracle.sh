#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}" "${RESULT_ROOT:?}"
cleanup() {
  bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >"$RESULT_ROOT/evidence/construction_cleanup.txt" 2>&1 || true
}
trap cleanup EXIT
set +e
python3 "$CASE_PRIVATE_ROOT/oracle/elastic_oracle.py"
rc=$?
set -e
cleanup
trap - EXIT
exit "$rc"

