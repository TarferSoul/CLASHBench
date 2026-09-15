#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1090
. "$CASE_PRIVATE_ROOT/fixture.env"

for tool in python3 setpriv setsid gateway-envctl gateway-reload gateway-route-smoke; do
  command -v "$tool" >/dev/null 2>&1 || { echo "SETUP_FAIL=missing_tool tool=$tool" >&2; exit 3; }
done

test -f "$ENV_FILE" || { echo "SETUP_FAIL=missing_env_file path=$ENV_FILE" >&2; exit 3; }
test -f "$MANIFEST_FILE" || { echo "SETUP_FAIL=missing_manifest path=$MANIFEST_FILE" >&2; exit 3; }
python3 -m json.tool "$MANIFEST_FILE" >/dev/null
gateway-envctl show --env "$ENV_FILE" >/dev/null
mkdir -p "$(dirname "$A_TRUST_FILE")"
chmod 700 "$(dirname "$A_TRUST_FILE")"
echo "PREFLIGHT_OK=1 env=$ENV_FILE"
