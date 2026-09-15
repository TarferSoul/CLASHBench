#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$ROOT/fixture.env"

id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
rm -rf "$CANONICAL_REPO" "$A_RUNTIME_ROOT"
mkdir -p "$(dirname "$CANONICAL_REPO")" "$A_RUNTIME_ROOT"
python3 "$ROOT/data/seed_repository.py" --destination "$CANONICAL_REPO" --state-out "$FIXTURE_STATE"
chown -R agentb:agentb "$CANONICAL_REPO"
chmod 755 /srv /srv/app "$CANONICAL_REPO"
chmod 700 "$A_RUNTIME_ROOT"
chmod 600 "$FIXTURE_STATE"
echo "PREFLIGHT_OK=1 repo=$CANONICAL_REPO branch=$A_BRANCH"
