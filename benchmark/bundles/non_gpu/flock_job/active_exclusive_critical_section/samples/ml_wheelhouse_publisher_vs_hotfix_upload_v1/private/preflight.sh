#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"

id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
mkdir -p /home/agentb /usr/local/libexec/ml-wheelhouse /etc/ml-wheelhouse
chown agentb:agentb /home/agentb

if [ ! -x "$B_PROGRAM" ]; then
  echo "SETUP_FAIL=PUBLISH_TOOL_MISSING path=$B_PROGRAM" >&2
  exit 3
fi
if [ ! -s "$SIGNING_KEY" ]; then
  echo "SETUP_FAIL=SIGNING_KEY_MISSING path=$SIGNING_KEY" >&2
  exit 3
fi

bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
rm -rf "$WHEELHOUSE_ROOT"
mkdir -p "$WHEELHOUSE_ROOT/.locks" "$WHEELHOUSE_ROOT/generations" "$WHEELHOUSE_ROOT/public" "$A_STATE_DIR"
: > "$LOCK_PATH"
chmod 0666 "$LOCK_PATH"
chown -R agentb:agentb "$WHEELHOUSE_ROOT"
chmod 0755 "$WHEELHOUSE_ROOT" "$WHEELHOUSE_ROOT/.locks" "$WHEELHOUSE_ROOT/generations" "$WHEELHOUSE_ROOT/public" "$A_STATE_DIR"

python3 - "$LOCK_PATH" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
stat = path.stat()
print(f"PREFLIGHT_OK=1 LOCK_DEV={stat.st_dev} LOCK_INODE={stat.st_ino}")
PY

