#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
rm -f "$A_STATUS_FILE" "$A_LOG_FILE"
runuser -u agentb -- env -i HOME=/home/agentb PATH=/usr/local/bin:/usr/bin:/bin \
  python3 "$A_WORKER_RUNTIME" --db "$DB_PATH" --status "$A_STATUS_FILE" --batch-id "$A_BATCH_ID" --generation "$A_GENERATION" \
  > "$A_LOG_FILE" 2>&1 &
launcher_pid=$!
ready=0
for _ in $(seq 1 140); do
  if [ -s "$A_STATUS_FILE" ] && python3 - "$A_STATUS_FILE" <<'PY' >/dev/null 2>&1
import json, sys, time
s = json.load(open(sys.argv[1]))
assert s["phase"] == "active"
assert s["progress_seq"] >= 5
assert time.time() - s["updated_at"] < 2
PY
  then ready=1; break; fi
  kill -0 "$launcher_pid" 2>/dev/null || break
  sleep 0.05
done
[ "$ready" = 1 ] || { tail -80 "$A_LOG_FILE" >&2 || true; exit 1; }
python3 - "$A_STATUS_FILE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
print(f"A_STARTED=1 pid={s['pid']} batch_id={s['batch_id']} generation={s['candidate_generation']} progress_seq={s['progress_seq']}")
PY
