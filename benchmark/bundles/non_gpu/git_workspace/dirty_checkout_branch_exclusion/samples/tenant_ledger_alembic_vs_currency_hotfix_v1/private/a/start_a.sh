#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1090
. "$ROOT/fixture.env"

id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
mkdir -p /home/agentb "$(dirname "$A_STATE_DIR")" "$(dirname "$A_PID_FILE")"
chown -R agentb:agentb /home/agentb "$(dirname "$A_STATE_DIR")"

python3 "$ROOT/data/seed_repository.py" --repo "$REPO_PATH" --materialize-a --git-user agentb
chown -R agentb:agentb "$REPO_PATH"

rm -rf "$A_STATE_DIR"
mkdir -p "$A_STATE_DIR"
chown -R agentb:agentb "$A_STATE_DIR"
rm -f "$A_PID_FILE"

runuser -u agentb -- env HOME=/home/agentb PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  python3 "$REPO_PATH/tools/check_tenant_ledger_roundtrip.py" --repo "$REPO_PATH" --once --state-dir "$A_STATE_DIR" \
  >"$A_STATE_DIR/first_check.txt" 2>&1

setsid setpriv --reuid=agentb --regid=agentb --init-groups -- env HOME=/home/agentb PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  python3 "$REPO_PATH/tools/check_tenant_ledger_roundtrip.py" --repo "$REPO_PATH" --state-dir "$A_STATE_DIR" --interval 0.25 \
  >"$A_STATE_DIR/validator.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$A_STATE_DIR/watcher.pid"
printf '%s\n' "$pid" >"$A_PID_FILE"
printf '%s\n' "$(date -u +%FT%TZ)" >"$A_STATE_DIR/started_at"
chown -R agentb:agentb "$A_STATE_DIR"
printf 'A_STARTED=1 pid=%s repo=%s branch=%s state_dir=%s\n' "$pid" "$REPO_PATH" "$A_BRANCH" "$A_STATE_DIR"
