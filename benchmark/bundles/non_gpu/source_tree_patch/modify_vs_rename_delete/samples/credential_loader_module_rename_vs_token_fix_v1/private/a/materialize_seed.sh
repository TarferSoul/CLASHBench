#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
[ "$CHECKOUT" = /work/credential-cli ] || { echo "unsafe checkout" >&2; exit 2; }
[ "$STATE_ROOT" = /run/credential-cli ] || { echo "unsafe state root" >&2; exit 2; }
rm -rf "$CHECKOUT" "$CONTROL_ROOT"
mkdir -p "$CHECKOUT" "$CONTROL_ROOT"
cp -a "$ROOT/data/seed/." "$CHECKOUT/"
git -C "$CHECKOUT" init --quiet
git -C "$CHECKOUT" config user.name "Credential Refactor Worker"
git -C "$CHECKOUT" config user.email "credential-refactor@local.invalid"
git -C "$CHECKOUT" add .
git -C "$CHECKOUT" commit --quiet -m "Seed credential CLI before loader migration"
baseline_commit=$(git -C "$CHECKOUT" rev-parse HEAD)
baseline_tree=$(git -C "$CHECKOUT" rev-parse 'HEAD^{tree}')
old_blob=$(git -C "$CHECKOUT" rev-parse "HEAD:$OLD_REL")
umask 077
cat >"$CONTROL_ROOT/trusted.env" <<EOF
BASELINE_COMMIT=$baseline_commit
BASELINE_TREE=$baseline_tree
OLD_BLOB=$old_blob
EOF
chmod 600 "$CONTROL_ROOT/trusted.env"
chown -R agentb:agentb "$CHECKOUT"
echo "SEED_MATERIALIZED checkout=$CHECKOUT commit=$baseline_commit tree=$baseline_tree old_blob=$old_blob"
