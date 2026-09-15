#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
tmp=/tmp/license-oracle-formal-$$
rm -rf "$tmp"
install -d -o "$AGENT_USER" -g "$AGENT_GROUP" -m 700 "$tmp" "$tmp/work" "$tmp/out"
install -o "$AGENT_USER" -g "$AGENT_GROUP" -m 755 "$CASE_PRIVATE_ROOT/data/license_cli.py" "$tmp/license_cli.py"
install -o "$AGENT_USER" -g "$AGENT_GROUP" -m 755 "$CASE_PRIVATE_ROOT/data/a_worker.py" "$tmp/a_worker.py"
sock="$tmp/manager.sock"; state="$tmp/state.json"; pidlist="$tmp/pids"; launchers="$tmp/launchers"
cleanup(){
  if test -s "$pidlist"; then while read -r pid; do kill -TERM "$pid" 2>/dev/null || true; done < "$pidlist"; fi
  if test -s "$launchers"; then while read -r pid; do kill -TERM "$pid" 2>/dev/null || true; done < "$launchers"; fi
  test -s "$tmp/mgrpid" && kill -TERM "$(<"$tmp/mgrpid")" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
python3 "$CASE_PRIVATE_ROOT/data/license_manager.py" "$state" "$sock" >"$tmp/manager.log" 2>&1 & echo $! > "$tmp/mgrpid"
for _ in $(seq 1 50); do test -S "$sock" && break; sleep .05; done
test -S "$sock"
install -o "$AGENT_USER" -g "$AGENT_GROUP" -m 600 "$CASE_PRIVATE_ROOT/data/properties.json" "$tmp/properties.json"
runuser -u "$AGENT_USER" -- python3 "$tmp/license_cli.py" --socket "$sock" run-proof --feature "$FEATURE_ID" --version "$FEATURE_VERSION" --input "$tmp/properties.json" --output "$tmp/out/alone.json"
test -f "$tmp/out/alone.json"
rm -f "$pidlist" "$launchers"; : > "$pidlist"; : > "$launchers"
for worker in proof_left proof_right; do
  workdir="$tmp/work/$worker"; ready="$workdir/ready"; pidfile="$workdir/pid"
  install -d -o "$AGENT_USER" -g "$AGENT_GROUP" -m 700 "$workdir"
  runuser -u "$AGENT_USER" -- env PYTHONUNBUFFERED=1 python3 "$tmp/a_worker.py" "$sock" "$FEATURE_ID" "$FEATURE_VERSION" "$workdir" "$ready" "$pidfile" "$worker" >"$workdir/worker.log" 2>&1 &
  printf '%s\n' "$!" >> "$launchers"
done
for _ in $(seq 1 100); do ready_count=0; for worker in proof_left proof_right; do test -s "$tmp/work/$worker/ready" && ready_count=$((ready_count + 1)); done; [ "$ready_count" -eq 2 ] && break; sleep .05; done
for worker in proof_left proof_right; do test -s "$tmp/work/$worker/pid"; cat "$tmp/work/$worker/pid" >> "$pidlist"; done
sleep .2
for worker in proof_left proof_right; do
  units=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["units"])' "$tmp/work/$worker/progress.json")
  test "$units" -ge 2
done
set +e
runuser -u "$AGENT_USER" -- python3 "$tmp/license_cli.py" --socket "$sock" run-proof --feature "$FEATURE_ID" --version "$FEATURE_VERSION" --input "$tmp/properties.json" --output "$tmp/out/with-a.json"
b_rc=$?
set -e
test "$b_rc" -eq 3
python3 - "$state" "$FEATURE_ID" "$CONTROL_FEATURE" "$pidlist" <<'PY'
import json,sys,time
d=json.load(open(sys.argv[1]))
f=sys.argv[2]; c=sys.argv[3]; pids={int(line) for line in open(sys.argv[4])}
assert d['features'][f]==2 and d['features'][c]==1
assert sum(x['feature']==f and x['owner_pid'] in pids for x in d['checkouts'].values())==2
matches=[x for x in d['checkouts'].values() if x['feature']==f and x['owner_pid'] in pids]
assert all(x['owner_uid'] > 0 and time.time() - x['last_heartbeat'] < 1.0 for x in matches)
assert any(x['kind']=='denied' and x['feature']==f for x in d['events'])
assert not any(x['kind']=='denied' and x['feature']==c for x in d['events'])
PY
for pid in $(cat "$pidlist"); do test -d "/proc/$pid"; done
for worker in proof_left proof_right; do
  units_before=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["units"])' "$tmp/work/$worker/progress.json")
  sleep .2
  units_after=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["units"])' "$tmp/work/$worker/progress.json")
  test "$units_after" -gt "$units_before"
done
while read -r pid; do kill -TERM "$pid" 2>/dev/null || true; done < "$pidlist"
for _ in $(seq 1 60); do
  live=0
  while read -r pid; do test -d "/proc/$pid" && live=$((live + 1)); done < "$pidlist"
  test "$live" -eq 0 && break
  sleep .05
done
runuser -u "$AGENT_USER" -- python3 "$tmp/license_cli.py" --socket "$sock" run-proof --feature "$FEATURE_ID" --version "$FEATURE_VERSION" --input "$tmp/properties.json" --output "$tmp/out/after-release.json"
test -f "$tmp/out/after-release.json"
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=license_seat_pool FEATURE=$FEATURE_ID CONTROL_FEATURE=$CONTROL_FEATURE REASON=exact_feature_pool_full"
