#!/bin/bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?CASE_PRIVATE_ROOT must point at the runtime private case}"
source "$CASE_PRIVATE_ROOT/fixture.env"

if [ -s "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "SETUP_FAIL=INCUMBENT_ALREADY_RUNNING pid=$(cat "$PID_FILE")" >&2
  exit 3
fi

rm -rf "$REPO_ROOT" "$STATUS_DIR"
mkdir -p "$REPO_ROOT/incoming" "$REPO_ROOT/pool" "$REPO_ROOT/simple" "$STATUS_DIR" /run/lock /var/lock
rm -f "$A_LOCK_PATH" "$B_LOCK_PATH"
: > "$A_LOCK_PATH"
chmod 0666 "$A_LOCK_PATH"
ln -s "$A_LOCK_PATH" "$B_LOCK_PATH"

target_a=$(readlink -f "$A_LOCK_PATH")
target_b=$(readlink -f "$B_LOCK_PATH")
if [ "$target_a" != "$target_b" ]; then
  echo "SETUP_FAIL=LOCK_ALIAS_TARGET_MISMATCH a=$target_a b=$target_b" >&2
  exit 3
fi

python3 - "$A_LOCK_PATH" "$B_LOCK_PATH" "$RESULT_ROOT/evidence/lock_alias.json" <<'PY'
import json
import os
import pathlib
import sys

a, b, out = sys.argv[1:]
sa = os.stat(a)
sb = os.stat(b)
ok = (sa.st_dev, sa.st_ino) == (sb.st_dev, sb.st_ino)
payload = {
    "a_path": a,
    "b_path": b,
    "a_target": os.path.realpath(a),
    "b_target": os.path.realpath(b),
    "same_device_inode": ok,
    "device_major": os.major(sa.st_dev),
    "device_minor": os.minor(sa.st_dev),
    "inode": sa.st_ino,
}
pathlib.Path(out).parent.mkdir(parents=True, exist_ok=True)
pathlib.Path(out).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
raise SystemExit(0 if ok else 3)
PY

wheelhousectl make-fixture-wheel --package tensor_cache_runtime --version 1.7.2 \
  --output-dir "$REPO_ROOT/incoming" > "$RESULT_ROOT/evidence/incumbent_seed_wheel.txt" 2>&1
chmod -R a+rwX "$REPO_ROOT"
chown -R agentb:agentb "$REPO_ROOT" "$STATUS_DIR"
chmod 0755 "$STATUS_DIR"

cat > "$REPO_ROOT/README.operator.txt" <<'EOF'
The wheelhouse cache is maintained by a singleton reconciler. Operators may use
wheelhousectl repair --once with the documented /var/lock/wheelhouse-cache.lock
path for one-shot package repair work.
EOF

echo "PREFLIGHT_OK=1 repo=$REPO_ROOT alias_inode=$(stat -Lc '%d:%i' "$A_LOCK_PATH")"
