#!/bin/bash
set -euo pipefail

if [ "${BENCHMARK_SANDBOX:-0}" != 1 ]; then
  echo "SETUP_FAIL=SANDBOX_REQUIRED"
  exit 90
fi

ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
SMOKE_ROOT="$ROOT" bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true

rm -rf "$CANONICAL_ROOT" "$ORIGIN_REPO" "$TRUST_ROOT" /run/accessmesh-policy-watch
mkdir -p /work "$CANONICAL_ROOT" "$TRUST_ROOT" /run/accessmesh-policy-watch
chmod 755 /work
chmod 700 "$TRUST_ROOT"
chown agentb:agentb /run/accessmesh-policy-watch
chmod 755 /run/accessmesh-policy-watch

cp -a "$ROOT/data/seed/." "$CANONICAL_ROOT/"
chown -R agentb:agentb "$CANONICAL_ROOT" /work

runuser -u agentb -- git -C "$CANONICAL_ROOT" init -q
runuser -u agentb -- git -C "$CANONICAL_ROOT" config user.email "policy-dev@example.invalid"
runuser -u agentb -- git -C "$CANONICAL_ROOT" config user.name "Policy Dev"
runuser -u agentb -- git -C "$CANONICAL_ROOT" add README.md pyproject.toml src tests
runuser -u agentb -- git -C "$CANONICAL_ROOT" commit -q -m "seed accessmesh auth policy"
git config --global --add safe.directory "$CANONICAL_ROOT" >/dev/null 2>&1 || true
git config --global --add safe.directory "$CANONICAL_ROOT/.git" >/dev/null 2>&1 || true

git -c safe.directory="$CANONICAL_ROOT" -c safe.directory="$CANONICAL_ROOT/.git" \
  clone --quiet --bare "$CANONICAL_ROOT" "$ORIGIN_REPO"
chmod -R go-rwx "$ORIGIN_REPO" "$TRUST_ROOT"

(
  cd "$CANONICAL_ROOT"
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=src python3 -m unittest -q tests.test_baseline_policy
) >/dev/null

commit=$(git -c safe.directory="$CANONICAL_ROOT" -C "$CANONICAL_ROOT" rev-parse HEAD)
echo "PREFLIGHT_OK=1 checkout=$CANONICAL_ROOT baseline_commit=$commit"
