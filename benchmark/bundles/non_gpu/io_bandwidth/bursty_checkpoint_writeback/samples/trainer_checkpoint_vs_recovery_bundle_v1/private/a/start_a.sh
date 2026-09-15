#!/bin/bash
set -euo pipefail

: "${PRIVATE_CASE:?}"
. "$PRIVATE_CASE/fixture.env"

id "$A_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$A_USER"
AGENT_GROUP=$(id -gn "$A_USER")

rm -rf "$A_RUNTIME_ROOT"
mkdir -p "$A_RUNTIME_ROOT/bin" "$A_RUNTIME_ROOT/logs" "$A_RUNTIME_ROOT/checkpoints"
install -m 750 -o "$A_USER" -g "$AGENT_GROUP" "$PRIVATE_CASE/a/checkpoint_trainer.py" "$A_RUNTIME_ROOT/bin/checkpoint_trainer.py"
chown -R "$A_USER:$AGENT_GROUP" "$A_RUNTIME_ROOT"
chmod 750 "$A_RUNTIME_ROOT" "$A_RUNTIME_ROOT/bin" "$A_RUNTIME_ROOT/logs" "$A_RUNTIME_ROOT/checkpoints"

: > "$A_RUNTIME_ROOT/logs/stdout.log"
: > "$A_RUNTIME_ROOT/logs/stderr.log"
chown "$A_USER:$AGENT_GROUP" "$A_RUNTIME_ROOT/logs/stdout.log" "$A_RUNTIME_ROOT/logs/stderr.log"

env_file="$A_RUNTIME_ROOT/a_env"
cat > "$env_file" <<EOF
A_RUNTIME_ROOT=$A_RUNTIME_ROOT
A_SHARD_COUNT=$A_SHARD_COUNT
A_SHARD_BYTES=$A_SHARD_BYTES
A_CHUNK_BYTES=$A_CHUNK_BYTES
A_COMPUTE_SECONDS=$A_COMPUTE_SECONDS
A_KEEP_GENERATIONS=$A_KEEP_GENERATIONS
EOF
if [ -n "${A_PHASE_GATE_DIR:-}" ]; then
  mkdir -p "$A_PHASE_GATE_DIR"
  chown "$A_USER:$AGENT_GROUP" "$A_PHASE_GATE_DIR"
  chmod 700 "$A_PHASE_GATE_DIR"
  {
    printf 'A_PHASE_GATE_DIR=%s\n' "$A_PHASE_GATE_DIR"
    printf 'A_WAIT_FOR_RELEASE=%s\n' "${A_WAIT_FOR_RELEASE:-1}"
  } >> "$env_file"
fi
chown "$A_USER:$AGENT_GROUP" "$env_file"
chmod 600 "$env_file"

rm -f "$A_RUNTIME_ROOT/worker.pid"
runuser -u "$A_USER" -- env PYTHONDONTWRITEBYTECODE=1 \
  WORKER_PID_FILE="$A_RUNTIME_ROOT/worker.pid" \
  A_ENV_FILE="$env_file" \
  A_SCRIPT="$A_RUNTIME_ROOT/bin/checkpoint_trainer.py" \
  bash -lc 'echo "$$" > "$WORKER_PID_FILE"; set -a; . "$A_ENV_FILE"; set +a; exec python3 "$A_SCRIPT"' \
  > "$A_RUNTIME_ROOT/logs/stdout.log" 2> "$A_RUNTIME_ROOT/logs/stderr.log" &
launcher_pid=$!
worker_pid=""
for _ in $(seq 1 100); do
  if [ -s "$A_RUNTIME_ROOT/worker.pid" ]; then
    worker_pid=$(cat "$A_RUNTIME_ROOT/worker.pid")
    if kill -0 "$worker_pid" 2>/dev/null; then
      break
    fi
  fi
  sleep 0.02
done
if [ -z "$worker_pid" ] || ! kill -0 "$worker_pid" 2>/dev/null; then
  echo "A_START_FAILED=1 launcher_pid=$launcher_pid" >&2
  exit 1
fi
printf '%s\n' "$worker_pid" > "$A_RUNTIME_ROOT/pid"
printf '%s\n' "$launcher_pid" > "$A_RUNTIME_ROOT/launcher.pid"
chown "$A_USER:$AGENT_GROUP" "$A_RUNTIME_ROOT/pid"
chmod 640 "$A_RUNTIME_ROOT/pid" "$A_RUNTIME_ROOT/launcher.pid" "$A_RUNTIME_ROOT/worker.pid"
echo "A_STARTED pid=$worker_pid launcher_pid=$launcher_pid root=$A_RUNTIME_ROOT"
