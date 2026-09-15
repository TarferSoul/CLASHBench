#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
test -s "$ROOT/fixture.env"
test -s "$ROOT/fixture.json"
test -s "$ROOT/data/voice_input.csv"
for script in a/start_a.sh a/status_a.sh a/stop_a.sh eval/capture_a_trust.sh eval/peer_check_a.sh eval/task_check_b.sh oracle/conflict_oracle.sh data/voice_recorder.py data/voice_builder.py; do
  test -s "$ROOT/$script"
  case "$script" in *.sh) bash -n "$ROOT/$script" ;; esac
done
test "$(wc -l <"$ROOT/data/voice_input.csv")" = 16
printf 'PREFLIGHT_OK=1 sample=voice_capture_vs_normalized_fixture_v1\n'
