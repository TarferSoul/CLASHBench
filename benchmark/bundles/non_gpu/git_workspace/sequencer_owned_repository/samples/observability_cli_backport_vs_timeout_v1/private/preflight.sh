#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$ROOT/fixture.env"

for command in git python3 runuser setsid sha256sum timeout; do
  command -v "$command" >/dev/null
done

test "$(id -u)" -eq 0
test -d "$CANONICAL_REPO/.git"
test -r "$FIXTURE_STATE"
git -C "$CANONICAL_REPO" fsck --no-progress --no-dangling >/dev/null
test "$(git -C "$CANONICAL_REPO" symbolic-ref --short HEAD)" = "$A_BRANCH"
test -n "$(git -C "$CANONICAL_REPO" rev-parse --verify "$B_REF")"

python3 -m py_compile \
  "$ROOT/data/seed_repository.py" \
  "$ROOT/data/workspace_state.py" \
  "$ROOT/data/qualification_worker.py"

echo "PREFLIGHT_OK=1 git_python_sequencer_fixture_ready"
