#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

export PYTHONPATH="$INSTALLED_BIN_DIR"
python3 "$INSTALLED_BIN_DIR/check_eval_report.py" \
  --json "$B_OUTPUT_JSON" \
  --html "$B_OUTPUT_HTML" \
  --source-root "$EVAL_FIXTURE_ROOT" \
  --request "$B_REQUEST_FILE" \
  --events "$A_EVENTS_FILE" \
  --max-elapsed "$B_DEADLINE_SECONDS"
