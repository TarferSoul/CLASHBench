#!/usr/bin/env bash
set -euo pipefail

ROOT=${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
. "$ROOT/fixture.env"

[ "$(id -u)" = 0 ] || { echo "PREFLIGHT_OK=0 REASON=root_required"; exit 1; }

missing=()
for command in bash python3 runuser setsid timeout ps awk sed grep mktemp sha256sum; do
  command -v "$command" >/dev/null 2>&1 || missing+=("$command")
done
[ ${#missing[@]} -eq 0 ] || { echo "PREFLIGHT_OK=0 REASON=missing_commands COMMANDS=${missing[*]}"; exit 1; }

[ -x "$TERRAFORM_BIN" ] || { echo "PREFLIGHT_OK=0 REASON=terraform_missing PATH=$TERRAFORM_BIN"; exit 1; }
version=$("$TERRAFORM_BIN" version -json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("terraform_version", ""))')
[ "$version" = "1.9.8" ] || { echo "PREFLIGHT_OK=0 REASON=terraform_version VERSION=$version"; exit 1; }

python3 -m py_compile "$ROOT/data/install_terraform.py" "$ROOT/data/ci_rollout.py"
python3 -m json.tool "$ROOT/fixture.json" >/dev/null
python3 -m json.tool "$ROOT/data/$FIXTURE_DATA_FILE" >/dev/null

echo "PREFLIGHT_OK=1 TERRAFORM_VERSION=$version WORKSPACE=$WORKSPACE_NAME"
