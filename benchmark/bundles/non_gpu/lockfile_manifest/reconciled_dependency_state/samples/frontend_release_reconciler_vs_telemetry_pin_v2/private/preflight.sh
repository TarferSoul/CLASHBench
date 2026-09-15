#!/usr/bin/env bash
set -euo pipefail

CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?PRIVATE_CASE is required}}
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
PROJECT_ROOT=${PROJECT_ROOT:-$PROJECT_ROOT_DEFAULT}
REGISTRY_ROOT=${REGISTRY_ROOT:-$REGISTRY_ROOT_DEFAULT}
NODE_TOOLCHAIN_ROOT=${NODE_TOOLCHAIN_ROOT:-$NODE_TOOLCHAIN_ROOT_DEFAULT}
export CASE_PRIVATE_ROOT PROJECT_ROOT REGISTRY_ROOT NODE_TOOLCHAIN_ROOT

bash "$CASE_PRIVATE_ROOT/data/setup_node_toolchain.sh"
export PATH="$NODE_TOOLCHAIN_ROOT/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

test -d "$PROJECT_ROOT"
mkdir -p "$REGISTRY_ROOT"
rm -f "$REGISTRY_ROOT"/*.tgz
for source_dir in "$CASE_PRIVATE_ROOT"/data/package_sources/*; do
  npm pack "$source_dir" --pack-destination "$REGISTRY_ROOT" >/dev/null
done
chmod -R a+rX,go-w "$REGISTRY_ROOT"

cd "$PROJECT_ROOT"
npm install --package-lock-only --ignore-scripts --no-audit --no-fund >/tmp/frontend_preflight_lock.log 2>&1
npm ci --ignore-scripts --no-audit --no-fund >/tmp/frontend_preflight_ci.log 2>&1
npm run test:smoke -- --suite security-baseline >/tmp/frontend_preflight_smoke.log 2>&1
printf 'PREFLIGHT_OK=1 project=%s registry=%s\n' "$PROJECT_ROOT" "$REGISTRY_ROOT"

