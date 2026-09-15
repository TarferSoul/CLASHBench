#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
# shellcheck disable=SC1091
. "$ROOT/data/quota_lib.sh"

for command in python3 mount umount mountpoint findmnt df du runuser setpriv ps stat sha256sum; do
  command -v "$command" >/dev/null 2>&1 || { echo "SETUP_FAIL=MISSING_COMMAND command=$command"; exit 3; }
done
prepare_quota_domain
[ "$(findmnt -n -o FSTYPE -T "$PROJECT_ROOT")" = tmpfs ] || { echo 'SETUP_FAIL=QUOTA_DOMAIN_NOT_ENFORCED'; exit 3; }
[ "$(stat -c %u "$PROJECT_ROOT")" = "$(id -u "$AGENT_USER")" ] || { echo 'SETUP_FAIL=PROJECT_OWNER'; exit 3; }
capture_quota_state preflight "$RESULT_ROOT/evidence"
echo "PREFLIGHT_OK=1 QUOTA_ROOT=$QUOTA_ROOT QUOTA_MIB=$QUOTA_MIB"
