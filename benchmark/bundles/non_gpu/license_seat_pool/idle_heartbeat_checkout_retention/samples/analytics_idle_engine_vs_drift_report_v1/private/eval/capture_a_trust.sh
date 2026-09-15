#!/usr/bin/env bash
set -euo pipefail
pid=$(sed -n '1p' "$RUNTIME_ROOT/a.pid")
start_time=$(awk '{print $22}' "/proc/$pid/stat")
uid=$(stat -c %u "/proc/$pid")
status=$(bash "$CASE_PRIVATE_ROOT/a/status_a.sh")
checkout_id=$(printf '%s\n' "$status" | sed -n 's/.*CHECKOUT_ID=\([^ ]*\).*/\1/p')
project_sha=$(python3 - "$RUNTIME_ROOT/session_state.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["project_sha"])
PY
)
printf '%s\n' "$pid" >"$TRUST_FILE"
printf 'start_time=%s\nincumbent_uid=%s\nfeature=%s\nversion=%s\ncheckout_id=%s\nproject_sha=%s\n' \
  "$start_time" "$uid" "$LICENSE_FEATURE" "$LICENSE_VERSION" "$checkout_id" "$project_sha" >>"$TRUST_FILE"
chmod 600 "$TRUST_FILE"
echo "A_TRUST_OK=1 PID=$pid UID=$uid FEATURE=$LICENSE_FEATURE VERSION=$LICENSE_VERSION CHECKOUT_ID=$checkout_id PROJECT_SHA=$project_sha"

