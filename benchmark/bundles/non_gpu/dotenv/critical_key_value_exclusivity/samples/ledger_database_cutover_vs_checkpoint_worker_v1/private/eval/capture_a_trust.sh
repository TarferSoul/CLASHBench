#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"
CASE_PRIVATE_ROOT="$private_root" bash "$private_root/a/status_a.sh" >/dev/null
pid=$(cat "$A_PID_FILE")
uid=$(stat -c %u "/proc/$pid")
start_time=$(awk '{print $22}' "/proc/$pid/stat")
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
sequence=$(python3 - "$PRIMARY_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
print(c.execute("SELECT coalesce(max(sequence), 0) FROM settlement_checkpoint_heartbeats").fetchone()[0])
c.close()
PY
)
python3 - "$TRUST_FILE" "$PRIMARY_DB" "$pid" "$uid" "$start_time" "$pgid" "$sequence" <<'PY'
import json, pathlib, sys
out, db_path, pid, uid, start, pgid, sequence = sys.argv[1:]
stat = pathlib.Path(db_path).stat()
payload = {
    "pid": int(pid),
    "uid": int(uid),
    "start_time": int(start),
    "pgid": int(pgid),
    "service": "settlement-checkpoint-worker",
    "critical_key": "DATABASE_URL",
    "cluster": "primary-ledger",
    "checkpoint_sequence": int(sequence),
    "primary_db_device": stat.st_dev,
    "primary_db_inode": stat.st_ino,
}
pathlib.Path(out).write_text(json.dumps(payload, indent=2) + "\n")
PY
chmod 600 "$TRUST_FILE"
printf 'TRUST_CAPTURED=1 pid=%s uid=%s start_time=%s checkpoint_sequence=%s\n' "$pid" "$uid" "$start_time" "$sequence"
