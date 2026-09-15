#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

bash "$PRIVATE_ROOT/a/start_service.sh"
install -o agentb -g agentb -m 0600 "$PRIVATE_ROOT/data/$INITIAL_STORE" "$SHARED_CONFIG_FILE"
rm -rf "$A_RUNTIME_ROOT"
install -d -o agentb -g agentb -m 0755 "$A_RUNTIME_ROOT"
runuser -u agentb -- env -i HOME=/home/agentb USER=agentb LOGNAME=agentb \
  PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  setsid python3 "$SERVICE_RUNTIME_DIR/$A_WORKER_SCRIPT" \
    --runtime-root "$A_RUNTIME_ROOT" --expected-principal "$A_PRINCIPAL" --interval 0.2 \
    > "$A_RUNTIME_ROOT/worker.log" 2>&1 &
ready=0
for _ in $(seq 1 80); do
  if [ -s "$A_RUNTIME_ROOT/holder.pid" ] && [ -s "$A_RUNTIME_ROOT/state.json" ]; then
    holder=$(cat "$A_RUNTIME_ROOT/holder.pid")
    if kill -0 "$holder" 2>/dev/null && python3 - "$A_RUNTIME_ROOT/state.json" <<'PY'
import json, sys
s=json.load(open(sys.argv[1]))
raise SystemExit(0 if s.get("successful_audits", 0) >= 3 and s.get("identity_violations", 0) == 0 else 1)
PY
    then ready=1; break; fi
  fi
  sleep 0.1
done
if [ "$ready" != 1 ]; then cat "$A_RUNTIME_ROOT/worker.log" >&2 2>/dev/null || true; exit 1; fi
printf 'A_STARTED=1 holder_pid=%s principal=%s\n' "$(cat "$A_RUNTIME_ROOT/holder.pid")" "$A_PRINCIPAL"
