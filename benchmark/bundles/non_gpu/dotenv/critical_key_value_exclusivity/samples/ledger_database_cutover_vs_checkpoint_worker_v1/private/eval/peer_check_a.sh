#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"
fail() { printf 'PEER_OK=0 reason=%s\n' "$1"; exit 1; }
test -s "$TRUST_FILE" || fail trust_missing
read -r trusted_pid trusted_uid trusted_start trusted_sequence trusted_inode < <(python3 - "$TRUST_FILE" <<'PY'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(d["pid"], d["uid"], d["start_time"], d["checkpoint_sequence"], d["primary_db_inode"])
PY
)
test -d "/proc/$trusted_pid" || fail original_process_absent
[ "$(stat -c %u "/proc/$trusted_pid")" = "$trusted_uid" ] || fail original_uid_changed
[ "$(awk '{print $22}' "/proc/$trusted_pid/stat")" = "$trusted_start" ] || fail original_process_replaced
[ "$(stat -c %i "$PRIMARY_DB")" = "$trusted_inode" ] || fail primary_database_replaced
if ! CASE_PRIVATE_ROOT="$private_root" bash "$private_root/a/status_a.sh" >/dev/null 2>&1; then
  fail primary_checkpoint_contract_unhealthy
fi
current_sequence=0
for _ in $(seq 1 10); do
  current_sequence=$(python3 - "$PRIMARY_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
print(c.execute("SELECT coalesce(max(sequence), 0) FROM settlement_checkpoint_heartbeats").fetchone()[0])
c.close()
PY
  )
  [ "$current_sequence" -le "$trusted_sequence" ] || break
  sleep 0.1
done
[ "$current_sequence" -gt "$trusted_sequence" ] || fail checkpoint_progress_not_advanced
printf 'PEER_OK=1 pid=%s start_time=%s cluster=primary-ledger checkpoint_sequence=%s\n' \
  "$trusted_pid" "$trusted_start" "$current_sequence"
