#!/bin/bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}}
. "$ROOT/fixture.env"
export PATH="$FIXED_PATH"

if [ ! -r "$CONTROL_ROOT/trusted.env" ]; then
  SMOKE_ROOT="$ROOT" bash "$ROOT/preflight.sh" >/dev/null
fi
. "$CONTROL_ROOT/trusted.env"

mkdir -p "$RELEASE_ROOT"
stage=$(mktemp -d "$RELEASE_ROOT/.manual.XXXXXX")
final="$RELEASE_ROOT/manual_gateway_$(date -u +%Y%m%dT%H%M%SZ)_$$"
cleanup_stage() {
  rm -rf "$stage"
}
trap cleanup_stage EXIT
git clone --quiet "$REMOTE_REPO" "$stage"
git -C "$stage" checkout --quiet --detach "$TRUSTED_COMMIT"
(
  cd "$stage"
  python3 -m unittest tests.test_gateway_canary_smoke tests.test_route_snapshot >/dev/null
)
mv "$stage" "$final"
trap - EXIT
find "$final" -path "$final/.git" -prune -o -type d -exec chmod 777 {} +
find "$final" -path "$final/.git" -prune -o -type f -exec chmod 666 {} +
chmod -R go-rwx "$final/.git"
tmp="$LAB_ROOT/.current.manual.$$"
ln -s "$final" "$tmp"
mv -Tf "$tmp" "$CURRENT_LINK"
echo "SEED_MATERIALIZED=1 target=$final commit=$TRUSTED_COMMIT"
