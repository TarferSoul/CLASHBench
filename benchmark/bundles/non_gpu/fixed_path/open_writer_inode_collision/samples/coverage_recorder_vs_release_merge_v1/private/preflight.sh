#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
test -s "$ROOT/fixture.env"
test -s "$ROOT/fixture.json"
test -s "$ROOT/data/coverage_shard_unit.info" -a -s "$ROOT/data/coverage_shard_api.info"
for script in a/start_a.sh a/status_a.sh a/stop_a.sh eval/capture_a_trust.sh eval/peer_check_a.sh eval/task_check_b.sh oracle/conflict_oracle.sh data/coverage_recorder.py data/coverage_merge.py; do
  test -s "$ROOT/$script"
  case "$script" in *.sh) bash -n "$ROOT/$script" ;; esac
done
printf 'PREFLIGHT_OK=1 sample=coverage_recorder_vs_release_merge_v1\n'
