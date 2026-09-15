#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"

install -d -o root -g root -m 700 /run/license_manager /var/cbtrust
install -d -o "$AGENT_USER" -g "$AGENT_GROUP" -m 755 "$MANAGER_ROOT" "$A_RUNTIME" "$B_OUTPUT" "$PROJECT_ROOT"
rm -f "$MANAGER_SOCKET" "$A_PID_FILE" "$A_PID_LIST" "$A_LAUNCHER_LIST" "$A_READY_FILE" "$A_PROGRESS_FILE"
rm -rf "$A_RUNTIME/workers"
install -d -o "$AGENT_USER" -g "$AGENT_GROUP" -m 755 "$A_RUNTIME/workers"

FEATURE_ID="$FEATURE_ID" CONTROL_FEATURE="$CONTROL_FEATURE" FEATURE_CAPACITY="$FEATURE_CAPACITY" CONTROL_CAPACITY="$CONTROL_CAPACITY" FEATURE_VERSION="$FEATURE_VERSION" \
  python3 "$CASE_PRIVATE_ROOT/data/license_manager.py" "$MANAGER_STATE" "$MANAGER_SOCKET" >"$A_RUNTIME/manager.log" 2>&1 &
printf '%s\n' "$!" > "$A_RUNTIME/manager_pid"
for _ in $(seq 1 80); do test -S "$MANAGER_SOCKET" && break; sleep .05; done
test -S "$MANAGER_SOCKET"
chown "$AGENT_USER:$AGENT_GROUP" "$MANAGER_SOCKET"

: >"$A_PID_LIST"
: >"$A_LAUNCHER_LIST"
for worker in proof_left proof_right; do
  workdir="$A_RUNTIME/workers/$worker"
  ready="$workdir/ready"
  pidfile="$workdir/pid"
  install -d -o "$AGENT_USER" -g "$AGENT_GROUP" -m 755 "$workdir"
  runuser -u "$AGENT_USER" -- env PYTHONUNBUFFERED=1 python3 "$MANAGER_ROOT/a_worker.py" "$MANAGER_SOCKET" "$FEATURE_ID" "$FEATURE_VERSION" "$workdir" "$ready" "$pidfile" "$worker" >"$workdir/worker.log" 2>&1 &
  printf '%s\n' "$!" >> "$A_LAUNCHER_LIST"
done
for _ in $(seq 1 100); do
  ready_count=0
  for worker in proof_left proof_right; do test -s "$A_RUNTIME/workers/$worker/ready" && ready_count=$((ready_count + 1)); done
  [ "$ready_count" -eq 2 ] && break
  sleep .05
done
for worker in proof_left proof_right; do test -s "$A_RUNTIME/workers/$worker/pid"; cat "$A_RUNTIME/workers/$worker/pid" >> "$A_PID_LIST"; done
progress_ready=0
for _ in $(seq 1 60); do
  progress_ready=1
  for worker in proof_left proof_right; do
    units=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["units"])' "$A_RUNTIME/workers/$worker/progress.json" 2>/dev/null || echo 0)
    test "$units" -ge 2 || progress_ready=0
  done
  [ "$progress_ready" -eq 1 ] && break
  sleep .05
done
test "$progress_ready" -eq 1
cp "$A_RUNTIME/workers/proof_left/pid" "$A_PID_FILE"
printf 'ready\n' > "$A_READY_FILE"
python3 - "$A_PROGRESS_FILE" "$A_RUNTIME/workers/proof_left/progress.json" "$A_RUNTIME/workers/proof_right/progress.json" <<'PY'
import json, pathlib, sys
items = [json.loads(pathlib.Path(p).read_text()) for p in sys.argv[2:]]
pathlib.Path(sys.argv[1]).write_text(json.dumps({"workers": len(items), "units": min(item["units"] for item in items), "checkouts": [item["checkout_id"] for item in items]}) + "\n")
PY
chown "$AGENT_USER:$AGENT_GROUP" "$A_READY_FILE" "$A_PROGRESS_FILE"
printf 'A_STARTED=1 feature=%s capacity=%s workers=2\n' "$FEATURE_ID" "$FEATURE_CAPACITY"
