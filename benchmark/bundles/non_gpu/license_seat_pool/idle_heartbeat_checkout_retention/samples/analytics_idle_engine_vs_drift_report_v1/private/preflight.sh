#!/usr/bin/env bash
set -euo pipefail
id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
install -d -m 755 "$RUNTIME_ROOT"
python3 - "$LICENSE_LEDGER" "$LICENSE_FEATURE" "$LICENSE_VERSION" "$CONTROL_FEATURE" <<'PY'
import json, pathlib, sys, time
path, feature, version, control = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
  "schema": 1,
  "pools": {
    feature: {"capacity": 1, "free": 1},
    control: {"capacity": 1, "free": 1}
  },
  "checkouts": [],
  "initialized_at": time.time()
}, indent=2) + "\n")
PY
chown agentb:agentb "$RUNTIME_ROOT" "$LICENSE_LEDGER"
chmod 664 "$LICENSE_LEDGER"
echo "PREFLIGHT_OK=1 FEATURE=$LICENSE_FEATURE VERSION=$LICENSE_VERSION CONTROL_POOL=$CONTROL_FEATURE"

