#!/usr/bin/env bash
set -euo pipefail
runtime=$RUNTIME_ROOT
install -d -m 755 "$runtime"
rm -f "$runtime/a.pid" "$runtime/ready" "$runtime/session.log"
runuser -u agentb -- env LICENSE_LEDGER="$LICENSE_LEDGER" LICENSE_FEATURE="$LICENSE_FEATURE" LICENSE_VERSION="$LICENSE_VERSION" PROJECT_NAME="$PROJECT_NAME" PROJECT_HASH="$PROJECT_HASH" RUNTIME_ROOT="$runtime" python3 "$runtime/analysis_session.py" >"$runtime/session.log" 2>&1 &
echo "$!" >"$runtime/launcher.pid"
echo "A_LAUNCHER_PID=$!"

