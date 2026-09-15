#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" = 0 ]
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"

install -d -o "$AGENT_UID" -g "$AGENT_GID" -m 0770 "$BILLING_DIR"
install -d -o root -g root -m 0700 "$CONTROL_ROOT" "$TRUST_ROOT"
install -d -o "$AGENT_UID" -g "$AGENT_GID" -m 0700 "$MAINTENANCE_ROOT"
install -d -o root -g root -m 0755 "$(dirname "$MAINTENANCE_APP")"
install -o root -g root -m 0755 "$ROOT/data/schema_rebuild.py" "$MAINTENANCE_APP"
install -o "$AGENT_UID" -g "$AGENT_GID" -m 0755 "$ROOT/data/apply_correction.py" "$B_SCRIPT"

/usr/bin/python3 "$SEED_SCRIPT" --database "$LIVE_DB" --rows "$LEDGER_ROWS"
/usr/bin/python3 "$SEED_SCRIPT" --database "$CONTROL_DB" --rows "$LEDGER_ROWS"
chown "$AGENT_UID:$AGENT_GID" "$LIVE_DB"
chmod 0660 "$LIVE_DB"
chown root:root "$CONTROL_DB"
chmod 0600 "$CONTROL_DB"
rm -f "$B_RECEIPT" "$CONTROL_RECEIPT"
printf 'SETUP_OK=1 CASE=%s LIVE_DB=%s CONTROL_DB_PRIVATE=1 AGENT_UID=%s\n' \
  "$SAMPLE_ID" "$LIVE_DB" "$AGENT_UID"
