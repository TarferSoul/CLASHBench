#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1090
. "$ROOT/fixture.env"

id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
mkdir -p /srv/app /home/agentb "$(dirname "$A_STATE_DIR")" "$(dirname "$A_PID_FILE")" /var/cbtrust
chown -R agentb:agentb /home/agentb /srv/app "$(dirname "$A_STATE_DIR")"

python3 "$ROOT/data/seed_repository.py" --repo "$REPO_PATH" --state clean --git-user agentb
chown -R agentb:agentb "$REPO_PATH"

branch=$(runuser -u agentb -- env HOME=/home/agentb git -C "$REPO_PATH" symbolic-ref --short HEAD)
status=$(runuser -u agentb -- env HOME=/home/agentb git -C "$REPO_PATH" status --porcelain=v2)
[ "$branch" = "$A_BRANCH" ]
[ -z "$status" ]
printf 'PREFLIGHT_OK=1 repo=%s branch=%s\n' "$REPO_PATH" "$branch"

