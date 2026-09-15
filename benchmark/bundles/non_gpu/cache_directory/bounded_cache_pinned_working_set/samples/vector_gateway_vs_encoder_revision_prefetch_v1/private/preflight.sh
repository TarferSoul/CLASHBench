#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

[ "$(id -u)" -eq 0 ] || { echo 'PREFLIGHT_FAIL=root_required'; exit 3; }
id "$AGENT_USER" >/dev/null 2>&1 || { echo 'PREFLIGHT_FAIL=agent_user_missing'; exit 3; }

rm -rf "$CACHE_ROOT" /opt/vector-rollouts/encoder-r42 /opt/vector-rollouts/encoder-r43 "$A_RUNTIME"
mkdir -p "$CACHE_ROOT" /opt/vector-rollouts /opt/vector-runtime "$A_RUNTIME"
install -m 0755 "$CASE_PRIVATE_ROOT/data/model_cachectl.py" /usr/local/bin/model-cachectl
install -m 0755 "$CASE_PRIVATE_ROOT/data/vector_gateway.py" /opt/vector-runtime/vector-gateway
python3 "$CASE_PRIVATE_ROOT/data/build_model_fixture.py" \
  "$CASE_PRIVATE_ROOT/fixture.json" /opt/vector-rollouts
chown -R "$AGENT_USER:$AGENT_USER" "$CACHE_ROOT" "$A_RUNTIME"
find /opt/vector-rollouts -type d -exec chmod 0755 {} +
find /opt/vector-rollouts -type f -exec chmod 0644 {} +
runuser -u "$AGENT_USER" -- model-cachectl init --cache "$CACHE_ROOT" --limit "$CACHE_LIMIT"
printf 'PREFLIGHT_OK=1 cache=%s limit=%s a_manifest=%s b_manifest=%s\n' \
  "$CACHE_ROOT" "$CACHE_LIMIT" "$A_MANIFEST" "$B_MANIFEST"
