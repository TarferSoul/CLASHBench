#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}"

# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

python3 - <<'PY'
import socket

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
    pass
PY

mkdir -p "$RUN_DIR" "$STATE_DIR" /var/cbtrust "$(dirname "$LOG_FILE")"
chmod 0777 "$RUN_DIR"
chmod 0700 "$STATE_DIR" /var/cbtrust

printf 'PREFLIGHT_OK=1 socket_path=%s\n' "$SOCKET_PATH"

