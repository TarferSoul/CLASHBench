#!/usr/bin/env bash
set -euo pipefail

PRIVATE_CASE=${PRIVATE_CASE:?PRIVATE_CASE is required}
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"

deps="$PRIVATE_CASE/deps"
mkdir -p "$TOOLCHAIN_ROOT"
(cd "$deps" && sha256sum -c SHA256SUMS)

rm -rf "$TOOLCHAIN_ROOT/node" "$TOOLCHAIN_ROOT/npm6-package" "$TOOLCHAIN_ROOT/npm8-package"
mkdir -p "$TOOLCHAIN_ROOT/node" "$TOOLCHAIN_ROOT/npm6-package" "$TOOLCHAIN_ROOT/npm8-package"
tar -xJf "$deps/node-v14.21.3-linux-x64.tar.xz" -C "$TOOLCHAIN_ROOT/node" --strip-components=1
tar -xzf "$deps/npm-6.14.18.tgz" -C "$TOOLCHAIN_ROOT/npm6-package" --strip-components=1
tar -xzf "$deps/npm-8.3.1.tgz" -C "$TOOLCHAIN_ROOT/npm8-package" --strip-components=1

printf '#!/usr/bin/env bash\nexec "%s/node/bin/node" "%s/npm6-package/bin/npm-cli.js" "$@"\n' "$TOOLCHAIN_ROOT" "$TOOLCHAIN_ROOT" >"$TOOLCHAIN_ROOT/npm6"
printf '#!/usr/bin/env bash\nexec "%s/node/bin/node" "%s/npm8-package/bin/npm-cli.js" "$@"\n' "$TOOLCHAIN_ROOT" "$TOOLCHAIN_ROOT" >"$TOOLCHAIN_ROOT/npm8"
ln -sfn "$TOOLCHAIN_ROOT/node/bin/node" "$TOOLCHAIN_ROOT/node16"
chmod a+rx "$TOOLCHAIN_ROOT/npm6" "$TOOLCHAIN_ROOT/npm8"
chmod -R a+rX "$TOOLCHAIN_ROOT"

[ "$("$TOOLCHAIN_ROOT/node16" --version)" = "$OLD_NODE_VERSION" ]
[ "$("$TOOLCHAIN_ROOT/npm6" --version)" = "$OLD_NPM_VERSION" ]
[ "$("$TOOLCHAIN_ROOT/npm8" --version)" = "$TARGET_NPM_VERSION" ]

check_root="/run/telemetry_pipeline_preflight_$$"
rm -rf "$check_root"
mkdir -p "$check_root"
cp -a "$PRIVATE_CASE/data/project/." "$check_root/"
"$TOOLCHAIN_ROOT/npm6" --prefix "$check_root" ci --offline --ignore-scripts >/dev/null
"$TOOLCHAIN_ROOT/node16" "$check_root/test/telemetry-export-smoke.js" >/dev/null
python3 "$PRIVATE_CASE/data/schema_probe.py" old "$check_root" >/dev/null
rm -rf "$check_root"
printf 'PREFLIGHT_OK=1 node=%s old_npm=%s target_npm=%s baseline_schema=%s\n' \
  "$OLD_NODE_VERSION" "$OLD_NPM_VERSION" "$TARGET_NPM_VERSION" "$OLD_SCHEMA"
