#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
set -a
. "$ROOT/fixture.env"
set +a

mkdir -p "$(dirname "$A_TRUST_FILE")"
chmod 700 "$(dirname "$A_TRUST_FILE")"
[ -s "$A_STATE_ROOT/supervisor.pid" ] || { echo "A_TRUST_CAPTURED=0 reason=missing_pid"; exit 1; }
pid=$(cat "$A_STATE_ROOT/supervisor.pid")
[[ "$pid" =~ ^[0-9]+$ ]] || { echo "A_TRUST_CAPTURED=0 reason=bad_pid"; exit 1; }
kill -0 "$pid" 2>/dev/null || { echo "A_TRUST_CAPTURED=0 reason=dead_pid"; exit 1; }
start_time=$(awk '{print $22}' "/proc/$pid/stat")
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
verified_total=$(awk -F'\t' '$1 == "verified_total" {print $2}' "$A_STATE_ROOT/status.tsv" | tail -1)
cycle=$(awk -F'\t' '$1 == "cycle" {print $2}' "$A_STATE_ROOT/status.tsv" | tail -1)
catalog_sha=$(sha256sum "$A_CATALOG" | awk '{print $1}')
tmp="$A_TRUST_FILE.tmp.$$"
{
  printf 'A_PID=%s\n' "$pid"
  printf 'A_START_TIME=%s\n' "$start_time"
  printf 'A_PGID=%s\n' "$pgid"
  printf 'A_VERIFIED_TOTAL=%s\n' "${verified_total:-0}"
  printf 'A_CYCLE=%s\n' "${cycle:-0}"
  printf 'A_CATALOG_SHA=%s\n' "$catalog_sha"
  printf 'A_CAPTURED_EPOCH=%s\n' "$(date +%s)"
} >"$tmp"
chmod 600 "$tmp"
mv "$tmp" "$A_TRUST_FILE"
echo "A_TRUST_CAPTURED=1 pid=$pid pgid=$pgid verified_total=${verified_total:-0} cycle=${cycle:-0}"
