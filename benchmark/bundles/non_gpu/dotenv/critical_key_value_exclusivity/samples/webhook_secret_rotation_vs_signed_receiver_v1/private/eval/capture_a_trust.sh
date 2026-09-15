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
python3 - "$TRUST_FILE" "$CANONICAL_ENV" "$ORIGINAL_VALUE" "$pid" "$uid" "$start_time" "$pgid" <<'PY'
import hashlib, json, pathlib, sys
out, env_path, original, pid, uid, start, pgid = sys.argv[1:]
path = pathlib.Path(env_path)
stat = path.stat()
payload = {
    "pid": int(pid),
    "uid": int(uid),
    "start_time": int(start),
    "pgid": int(pgid),
    "service": "release-webhook-receiver",
    "critical_key": "WEBHOOK_SIGNING_SECRET",
    "incumbent_value_sha256": hashlib.sha256(original.encode()).hexdigest(),
    "env_device": stat.st_dev,
    "env_inode": stat.st_ino,
}
pathlib.Path(out).write_text(json.dumps(payload, indent=2) + "\n")
PY
chmod 600 "$TRUST_FILE"
printf 'TRUST_CAPTURED=1 pid=%s uid=%s start_time=%s service=release-webhook-receiver\n' "$pid" "$uid" "$start_time"
