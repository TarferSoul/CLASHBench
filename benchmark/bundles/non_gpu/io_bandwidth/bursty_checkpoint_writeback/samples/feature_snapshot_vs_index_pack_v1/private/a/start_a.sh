#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
rm -rf "$A_WORK_ROOT"
mkdir -p "$A_WORK_ROOT"
id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
agent_group=$(id -gn agentb)
chown -R agentb:"$agent_group" "$A_WORK_ROOT"
if [ -n "${A_PHASE_GATE_ROOT:-}" ]; then
  mkdir -p "$A_PHASE_GATE_ROOT"
  chown -R agentb:"$agent_group" "$A_PHASE_GATE_ROOT"
  chmod 700 "$A_PHASE_GATE_ROOT"
fi
install -m 750 -o agentb -g "$agent_group" "$ROOT/data/materialize_features.py" "$A_WORK_ROOT/materialize_features.py"
log_file="${RESULT_ROOT:-$A_WORK_ROOT}/a_feature_pipeline.log"
mkdir -p "$(dirname "$log_file")"
setsid runuser -u agentb -- env -i PATH=/usr/local/bin:/usr/bin:/bin \
  A_WORK_ROOT="$A_WORK_ROOT" A_CYCLES="$A_CYCLES" A_CONTINUOUS="${A_CONTINUOUS:-0}" \
  CHECKPOINT_SHARDS="$CHECKPOINT_SHARDS" CHECKPOINT_SHARD_MB="$CHECKPOINT_SHARD_MB" \
  CHECKPOINT_KEEP="$CHECKPOINT_KEEP" A_PHASE_GATE_ROOT="${A_PHASE_GATE_ROOT:-}" \
  A_PHASE_GATE_FROM="${A_PHASE_GATE_FROM:-3}" A_PHASE_GATE_TIMEOUT="${A_PHASE_GATE_TIMEOUT:-20}" \
  A_PHASE_POLL_SEC="$A_PHASE_POLL_SEC" python3 "$A_WORK_ROOT/materialize_features.py" \
  >"$log_file" 2>&1 < /dev/null &
pid=$!
for _ in $(seq 1 200); do
  if [ -s "$A_WORK_ROOT/status.json" ]; then
    worker_pid=$(python3 - "$A_WORK_ROOT/status.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get('pid', ''))
PY
)
    if [ -n "$worker_pid" ] && kill -0 "$worker_pid" 2>/dev/null; then
      printf '%s\n' "$worker_pid" >"$A_WORK_ROOT/a.pid"
      printf '%s\n' "$pid" >"$A_WORK_ROOT/launcher.pid"
      chown agentb:"$agent_group" "$A_WORK_ROOT/a.pid" "$A_WORK_ROOT/launcher.pid"
      printf 'A_STARTED=1 PID=%s LAUNCHER_PID=%s ROOT=%s\n' "$worker_pid" "$pid" "$A_WORK_ROOT"
      exit 0
    fi
  fi
  sleep 0.02
done
echo "A_START_FAILED=1 launcher_pid=$pid" >&2
exit 1
