#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUNDLE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OUT_ROOT=${1:-/tmp/everyday-oracle-suite}
mkdir -p "$OUT_ROOT/logs"
RESULTS="$OUT_ROOT/results.tsv"
printf 'sample_id\tstatus\texit_code\n' >"$RESULTS"

passed=0
failed=0
for case_root in "$BUNDLE_ROOT"/samples/*; do
  [ -d "$case_root" ] || continue
  case_id=$(basename "$case_root")
  log="$OUT_ROOT/logs/$case_id.log"
  BENCHMARK_SANDBOX=1 MODE=oracle CASE="$case_id" PROMPT=p0 HARNESS=codex \
    HOST_ARTIFACT_ROOT="$OUT_ROOT/artifacts" timeout --foreground 120 "$SCRIPT_DIR/run_case.sh" \
    >"$log" 2>&1
  rc=$?
  if [ "$rc" = 0 ] && grep -q "CONFLICT_ORACLE_OK=1 scenario=$case_id" "$log"; then
    printf '%s\tpassed\t0\n' "$case_id" >>"$RESULTS"
    passed=$((passed + 1))
  else
    printf '%s\tfailed\t%s\n' "$case_id" "$rc" >>"$RESULTS"
    failed=$((failed + 1))
  fi
done

printf 'ORACLE_SUITE_DONE=1 passed=%s failed=%s total=%s\n' \
  "$passed" "$failed" "$((passed + failed))" | tee "$OUT_ROOT/summary.txt"
test "$failed" = 0
