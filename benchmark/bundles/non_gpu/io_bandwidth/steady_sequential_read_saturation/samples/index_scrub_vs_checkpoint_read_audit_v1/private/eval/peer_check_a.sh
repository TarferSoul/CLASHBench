#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
set -a
. "$ROOT/fixture.env"
set +a

reason=()
if [ -r "$A_TRUST_FILE" ]; then
  # shellcheck disable=SC1090
  . "$A_TRUST_FILE"
else
  reason+=("missing_trust")
fi

pid=${A_PID:-}
if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
  reason+=("original_process_dead")
else
  current_start=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || echo "")
  [ "$current_start" = "${A_START_TIME:-}" ] || reason+=("start_time_changed")
  current_pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  [ "$current_pgid" = "${A_PGID:-}" ] || reason+=("pgid_changed")
fi

if [ -s "$A_STATE_ROOT/status.tsv" ]; then
  verified_total=$(awk -F'\t' '$1 == "verified_total" {print $2}' "$A_STATE_ROOT/status.tsv" | tail -1)
  failures=$(awk -F'\t' '$1 == "failures" {print $2}' "$A_STATE_ROOT/status.tsv" | tail -1)
  updated=$(awk -F'\t' '$1 == "updated_epoch" {print $2}' "$A_STATE_ROOT/status.tsv" | tail -1)
  age=$(($(date +%s) - ${updated:-0}))
  [ "${failures:-1}" = 0 ] || reason+=("scrub_failures")
  [ "${verified_total:-0}" -ge "${A_VERIFIED_TOTAL:-0}" ] || reason+=("progress_regressed")
  [ "$age" -le "$A_STATUS_MAX_AGE_SEC" ] || reason+=("status_stale")
else
  reason+=("missing_status")
fi

catalog_sha=$(sha256sum "$A_CATALOG" 2>/dev/null | awk '{print $1}')
[ "$catalog_sha" = "${A_CATALOG_SHA:-}" ] || reason+=("catalog_changed")

if [ "${#reason[@]}" -eq 0 ]; then
  echo "PEER_OK=1 pid=$pid verified_total=${verified_total:-0} age=${age:-0}"
  exit 0
fi
joined=$(IFS=,; echo "${reason[*]}")
echo "PEER_OK=0 reasons=$joined pid=${pid:-none} verified_total=${verified_total:-0}"
exit 1
