#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
set -a
. "$ROOT/fixture.env"
set +a

status_field() {
  awk -F'\t' -v key="$1" '$1 == key {print $2}' "$A_STATE_ROOT/status.tsv" 2>/dev/null | tail -1
}

[ -s "$A_STATE_ROOT/supervisor.pid" ] || { echo "A_STATUS=BAD reason=missing_pid"; exit 1; }
pid=$(cat "$A_STATE_ROOT/supervisor.pid")
[[ "$pid" =~ ^[0-9]+$ ]] || { echo "A_STATUS=BAD reason=bad_pid"; exit 1; }
kill -0 "$pid" 2>/dev/null || { echo "A_STATUS=BAD reason=process_dead pid=$pid"; exit 1; }
[ -s "$A_STATE_ROOT/status.tsv" ] || { echo "A_STATUS=BAD reason=missing_status pid=$pid"; exit 1; }

phase=$(status_field phase)
verified_total=$(status_field verified_total)
cycle=$(status_field cycle)
failures=$(status_field failures)
updated=$(status_field updated_epoch)
now=$(date +%s)
age=$((now - ${updated:-0}))

[ "${failures:-1}" = 0 ] || { echo "A_STATUS=BAD reason=failures pid=$pid failures=$failures"; exit 1; }
[ "${verified_total:-0}" -ge "$A_SEGMENT_COUNT" ] || { echo "A_STATUS=WAIT pid=$pid phase=$phase verified_total=${verified_total:-0}"; exit 1; }
[ "$age" -le "$A_STATUS_MAX_AGE_SEC" ] || { echo "A_STATUS=BAD reason=stale_status age=$age pid=$pid"; exit 1; }

echo "A_STATUS=OK pid=$pid phase=$phase cycle=${cycle:-0} verified_total=${verified_total:-0} age=$age"
