#!/usr/bin/env bash
set -euo pipefail

CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?PRIVATE_CASE is required}}
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
WHEELHOUSE_ROOT=${WHEELHOUSE_ROOT:-$WHEELHOUSE_ROOT_DEFAULT}
UV_TOOLCHAIN_ROOT=${UV_TOOLCHAIN_ROOT:-$UV_TOOLCHAIN_ROOT_DEFAULT}

mkdir -p "$UV_TOOLCHAIN_ROOT/bin" "$WHEELHOUSE_ROOT"
if [ -x "$CASE_PRIVATE_ROOT/deps/uv" ]; then
  install -m 755 "$CASE_PRIVATE_ROOT/deps/uv" "$UV_TOOLCHAIN_ROOT/bin/uv"
elif command -v uv >/dev/null 2>&1; then
  install -m 755 "$(command -v uv)" "$UV_TOOLCHAIN_ROOT/bin/uv"
else
  echo "SETUP_FAIL=UV_MISSING" >&2
  exit 20
fi

"$UV_TOOLCHAIN_ROOT/bin/uv" --version | grep -q "uv $UV_VERSION_EXPECTED" || {
  "$UV_TOOLCHAIN_ROOT/bin/uv" --version >&2 || true
  echo "SETUP_FAIL=UV_VERSION" >&2
  exit 21
}

python3 "$CASE_PRIVATE_ROOT/data/build_fixture_wheels.py" \
  --source "$CASE_PRIVATE_ROOT/data/wheel_sources/packages.json" \
  --dest "$WHEELHOUSE_ROOT" >/tmp/llm_eval_fixture_wheels.log 2>&1

shopt -s nullglob
third_party=( "$CASE_PRIVATE_ROOT"/deps/third_party_wheels/*.whl )
if [ "${#third_party[@]}" -gt 0 ]; then
  cp "${third_party[@]}" "$WHEELHOUSE_ROOT/"
fi
shopt -u nullglob

chmod -R a+rX,go-w "$WHEELHOUSE_ROOT"
printf 'UV_TOOLCHAIN_OK=1 uv=%s wheelhouse=%s wheels=%s\n' \
  "$("$UV_TOOLCHAIN_ROOT/bin/uv" --version)" "$WHEELHOUSE_ROOT" "$(find "$WHEELHOUSE_ROOT" -maxdepth 1 -name '*.whl' | wc -l)"
