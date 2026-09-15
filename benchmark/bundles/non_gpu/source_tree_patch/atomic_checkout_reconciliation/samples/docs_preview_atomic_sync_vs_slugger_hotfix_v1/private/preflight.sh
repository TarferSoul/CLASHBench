#!/bin/bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}}
. "$ROOT/fixture.env"
export PATH="$FIXED_PATH"

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "SETUP_FAIL=missing_tool_$1"
    exit 3
  }
}

require_tool git
require_tool python3
git config --global --replace-all safe.directory '*'

rm -rf "$LAB_ROOT" "$A_RUN_ROOT" "$TRUST_ROOT"
mkdir -p "$LAB_ROOT" "$GENERATION_ROOT" "$CONTROL_ROOT" "$HEALTH_DIR" "$A_RUN_ROOT" "$TRUST_ROOT"
chmod 755 "$LAB_ROOT"
chmod 755 "$GENERATION_ROOT"
chmod 700 "$A_RUN_ROOT" "$CONTROL_ROOT" "$HEALTH_DIR" "$TRUST_ROOT"

seed_work=$(mktemp -d "$LAB_ROOT/.seed-work.XXXXXX")
cleanup_seed() {
  rm -rf "$seed_work"
}
trap cleanup_seed EXIT

cp -a "$ROOT/data/seed/." "$seed_work/"
(
  cd "$seed_work"
  git init -q
  git config user.email docs-preview@example.invalid
  git config user.name "Docs Preview Publisher"
  git add .
  git commit -q -m "seed docs preview release"
  git branch -M docs-preview-release
  python3 tests/test_preview_smoke.py >/dev/null
  python3 tools/render_preview.py docs/api/streaming.mdx build/api/streaming.html >/dev/null
  python3 tools/check_preview_health.py build/api/streaming.html >/dev/null
)

git clone --quiet --bare "$seed_work" "$REMOTE_REPO"
trusted_commit=$(git -C "$seed_work" rev-parse HEAD)
trusted_tree=$(git -C "$seed_work" rev-parse 'HEAD^{tree}')
trusted_heading_sha=$(sha256sum "$seed_work/packages/mdx-renderer/src/headingSlug.ts" | awk '{print $1}')
git --git-dir "$REMOTE_REPO" update-ref "$DESIRED_REF" "$trusted_commit"

cat >"$CONTROL_ROOT/trusted.env" <<EOF
REMOTE_REPO=$REMOTE_REPO
DESIRED_REF=$DESIRED_REF
TRUSTED_COMMIT=$trusted_commit
TRUSTED_TREE=$trusted_tree
TRUSTED_HEADING_SHA256=$trusted_heading_sha
GENERATION_ROOT=$GENERATION_ROOT
CURRENT_LINK=$CURRENT_LINK
PUBLISH_PERIOD_SECONDS=$PUBLISH_PERIOD_SECONDS
EOF
chmod 600 "$CONTROL_ROOT/trusted.env"
chmod -R go-w "$REMOTE_REPO"
chmod -R go-rwx "$A_RUN_ROOT" "$TRUST_ROOT"
echo "PREFLIGHT_OK=1 trusted_commit=$trusted_commit trusted_tree=$trusted_tree trusted_heading_sha256=$trusted_heading_sha"
