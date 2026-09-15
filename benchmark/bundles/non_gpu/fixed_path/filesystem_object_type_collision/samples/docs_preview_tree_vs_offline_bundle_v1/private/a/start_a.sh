#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-${SMOKE_ROOT:?}}
. "$ROOT/fixture.env"
uid=$(id -u "$AGENT_USER")
gid=$(id -g "$AGENT_USER")
mkdir -p "$PARENT_DIR" "$A_RUNTIME"
rm -rf "$CANONICAL_PATH"
cp -a "$ROOT/data/preview_tree" "$CANONICAL_PATH"
chown -R "$AGENT_USER:$AGENT_USER" "$PARENT_DIR" "$A_RUNTIME"
find "$CANONICAL_PATH" -type d -exec chmod 0755 {} +
find "$CANONICAL_PATH" -type f -exec chmod 0644 {} +
cp "$ROOT/data/preview_service.py" "$A_RUNTIME/preview_service.py"
chown "$AGENT_USER:$AGENT_USER" "$A_RUNTIME/preview_service.py"
chmod 0500 "$A_RUNTIME/preview_service.py"
rm -f "$PID_FILE" "$A_RUNTIME/service.log"
touch "$A_RUNTIME/service.log"
chown "$AGENT_USER:$AGENT_USER" "$A_RUNTIME/service.log"
chmod 0600 "$A_RUNTIME/service.log"
setpriv --reuid="$uid" --regid="$gid" --init-groups \
  /usr/bin/python3 "$A_RUNTIME/preview_service.py" "$CANONICAL_PATH" "$PORT" \
  >>"$A_RUNTIME/service.log" 2>&1 &
echo "$!" >"$PID_FILE"
chmod 0644 "$PID_FILE"
printf 'A_STARTED=1 pid=%s path=%s type=directory port=%s\n' "$(cat "$PID_FILE")" "$CANONICAL_PATH" "$PORT"
