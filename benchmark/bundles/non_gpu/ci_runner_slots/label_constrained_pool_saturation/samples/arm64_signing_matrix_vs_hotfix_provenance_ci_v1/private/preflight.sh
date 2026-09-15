#!/usr/bin/env bash
set -euo pipefail
command -v python3 >/dev/null
command -v openssl >/dev/null
test -x /usr/local/bin/ci-runnerctl
test -x /usr/local/lib/lane-ci/scheduler.py
test -x /usr/local/lib/lane-ci/repro_job.py
python3 -m json.tool "$CI_RUNTIME_DIR/scheduler-config.json" >/dev/null
echo 'PREFLIGHT_OK=1 scheduler=LaneCI version=laneci-2.4.0 capability=rsa-signing'
