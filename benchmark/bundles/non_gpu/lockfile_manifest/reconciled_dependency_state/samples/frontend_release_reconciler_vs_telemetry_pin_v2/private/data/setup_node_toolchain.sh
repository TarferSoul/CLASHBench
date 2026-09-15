#!/usr/bin/env bash
set -euo pipefail

CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?CASE_PRIVATE_ROOT is required}
TOOLCHAIN_ROOT=${NODE_TOOLCHAIN_ROOT:-/opt/npm-reconciler-toolchain}
NODE_ARCHIVE="$CASE_PRIVATE_ROOT/deps/node-v20.15.1-linux-x64.tar.xz"
NPM_ARCHIVE="$CASE_PRIVATE_ROOT/deps/npm-10.8.2.tgz"
NODE_DIR="$TOOLCHAIN_ROOT/node-v20.15.1-linux-x64"
NPM_DIR="$TOOLCHAIN_ROOT/npm-10.8.2"
BIN_DIR="$TOOLCHAIN_ROOT/bin"

mkdir -p "$TOOLCHAIN_ROOT" "$BIN_DIR"
if [ ! -x "$NODE_DIR/bin/node" ]; then
  rm -rf "$NODE_DIR"
  tar -xJf "$NODE_ARCHIVE" -C "$TOOLCHAIN_ROOT"
fi
if [ ! -f "$NPM_DIR/bin/npm-cli.js" ]; then
  rm -rf "$NPM_DIR"
  mkdir -p "$NPM_DIR"
  tar -xzf "$NPM_ARCHIVE" -C "$NPM_DIR" --strip-components=1
fi

ln -sfn "$NODE_DIR/bin/node" "$BIN_DIR/node"
printf '#!/usr/bin/env bash\nexec "%s" "%s" "$@"\n' "$NODE_DIR/bin/node" "$NPM_DIR/bin/npm-cli.js" >"$BIN_DIR/npm"
printf '#!/usr/bin/env bash\nexec "%s" "%s" "$@"\n' "$NODE_DIR/bin/node" "$NPM_DIR/bin/npx-cli.js" >"$BIN_DIR/npx"
chmod 755 "$BIN_DIR/npm" "$BIN_DIR/npx"

"$BIN_DIR/node" --version >/dev/null
"$BIN_DIR/npm" --version >/dev/null
printf 'NODE_TOOLCHAIN_OK=1 root=%s node=%s npm=%s\n' "$TOOLCHAIN_ROOT" "$("$BIN_DIR/node" --version)" "$("$BIN_DIR/npm" --version)"

