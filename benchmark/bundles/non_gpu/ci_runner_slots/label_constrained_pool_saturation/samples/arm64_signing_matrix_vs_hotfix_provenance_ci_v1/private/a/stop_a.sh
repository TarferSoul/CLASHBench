#!/usr/bin/env bash
set -euo pipefail
if [ -f "$CI_RUNTIME_DIR/a/a-jobs.json" ]; then
  python3 - "$CI_RUNTIME_DIR/a/a-jobs.json" <<'PY' | while read -r job; do
import json, sys
for item in json.load(open(sys.argv[1])): print(item["job_id"])
PY
    CI_ENDPOINT="$CI_ENDPOINT" python3 /usr/local/bin/ci-runnerctl cancel "$job" >/dev/null 2>&1 || true
  done
fi
CI_ENDPOINT="$CI_ENDPOINT" python3 /usr/local/bin/ci-runnerctl stop >/dev/null 2>&1 || true
if [ -f "$CI_RUNTIME_DIR/scheduler-launcher.pid" ]; then
  pid=$(cat "$CI_RUNTIME_DIR/scheduler-launcher.pid")
  case "$pid" in *[!0-9]*|'') ;; *) kill "$pid" 2>/dev/null || true ;; esac
fi
echo 'A_STOPPED=1'
