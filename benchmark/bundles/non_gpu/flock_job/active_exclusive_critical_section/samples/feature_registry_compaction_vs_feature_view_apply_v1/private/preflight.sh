#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"

id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
mkdir -p /usr/local/libexec/feature-store-registry /etc/feature-store "$TRUST_ROOT"
install -o root -g root -m 0755 "$CASE_PRIVATE_ROOT/data/feature_registry_fixture.py" "$A_FIXTURE_PROGRAM"
install -o root -g root -m 0755 "$CASE_PRIVATE_ROOT/a/registry_compactor.py" "$A_RUNTIME_PROGRAM"
if [ ! -s "$SIGNING_KEY" ]; then
  install -o root -g root -m 0644 "$CASE_PUBLIC_ROOT/workload/registry.key" "$SIGNING_KEY"
fi
python3 "$A_FIXTURE_PROGRAM" reset --root "$REGISTRY_ROOT" --signing-key "$SIGNING_KEY" --base-count 8
chown -R agentb:agentb /srv/feature-store
chmod 0755 /srv/feature-store "$REGISTRY_ROOT" "$A_STATE_DIR" "$REGISTRY_ROOT/public" "$REGISTRY_ROOT/generations"
chmod 0775 "$REGISTRY_ROOT/.locks"
chmod 0666 "$LOCK_PATH"
"$B_PROGRAM" registry apply --help >/dev/null
python3 - "$LOCK_PATH" "$REGISTRY_ROOT/public/current/registry.db" "$REGISTRY_ROOT/public/current/registry.json" <<'PY'
import pathlib
import sqlite3
import sys
lock, db, registry = map(pathlib.Path, sys.argv[1:])
assert lock.exists(), "lock file missing"
assert db.exists(), "registry.db missing"
assert registry.exists(), "registry.json missing"
connection = sqlite3.connect(db)
try:
    count = connection.execute("select count(*) from feature_views").fetchone()[0]
finally:
    connection.close()
assert count >= 8, f"unexpected base view count {count}"
print(f"PREFLIGHT_OK=1 LOCK_INODE={lock.stat().st_ino} BASE_FEATURE_VIEWS={count}")
PY

