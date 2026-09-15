#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

[ "$(id -u)" -eq 0 ] || { echo 'PREFLIGHT_FAIL=root_required'; exit 3; }
id "$AGENT_USER" >/dev/null 2>&1 || { echo 'PREFLIGHT_FAIL=agent_user_missing'; exit 3; }

rm -rf "$CACHE_ROOT" /opt/release-images/platform-runtime-2026.08.03 \
  /opt/release-images/fraud-api-2026.08.04 "$A_RUNTIME"
mkdir -p "$CACHE_ROOT" /opt/release-images /opt/release-registry "$A_RUNTIME"
install -m 0755 "$CASE_PRIVATE_ROOT/data/oci_cachectl.py" /usr/local/bin/oci-cachectl
install -m 0755 "$CASE_PRIVATE_ROOT/data/release_registry.py" /opt/release-registry/release-registry
python3 "$CASE_PRIVATE_ROOT/data/build_oci_fixture.py" \
  "$CASE_PRIVATE_ROOT/fixture.json" /opt/release-images
chown -R "$AGENT_USER:$AGENT_USER" "$CACHE_ROOT" "$A_RUNTIME"
find /opt/release-images -type d -exec chmod 0755 {} +
find /opt/release-images -type f -exec chmod 0644 {} +
runuser -u "$AGENT_USER" -- oci-cachectl init-store --store "$CACHE_ROOT" --limit "$CACHE_LIMIT"
printf 'PREFLIGHT_OK=1 store=%s max_content_bytes=%s a_manifest=%s b_manifest=%s\n' \
  "$CACHE_ROOT" "$CACHE_LIMIT" "$A_MANIFEST" "$B_MANIFEST"
