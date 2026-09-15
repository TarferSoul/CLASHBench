#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
tmp=/tmp/license-oracle-formal-$$
rm -rf "$tmp"
install -d -o "$AGENT_USER" -g "$AGENT_GROUP" -m 700 "$tmp" "$tmp/work" "$tmp/out"
install -o "$AGENT_USER" -g "$AGENT_GROUP" -m 755 "$CASE_PRIVATE_ROOT/data/license_cli.py" "$tmp/license_cli.py"
install -o "$AGENT_USER" -g "$AGENT_GROUP" -m 755 "$CASE_PRIVATE_ROOT/data/a_worker.py" "$tmp/a_worker.py"
sock="$tmp/manager.sock"; state="$tmp/state.json"; ready="$tmp/ready"; pidfile="$tmp/pid"
cleanup(){ test -s "$pidfile" && kill -TERM "$(<"$pidfile")" 2>/dev/null || true; test -s "$tmp/mgrpid" && kill -TERM "$(<"$tmp/mgrpid")" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
python3 "$CASE_PRIVATE_ROOT/data/license_manager.py" "$state" "$sock" >"$tmp/manager.log" 2>&1 & echo $! > "$tmp/mgrpid"
for _ in $(seq 1 50); do test -S "$sock" && break; sleep .05; done
test -S "$sock"
install -o "$AGENT_USER" -g "$AGENT_GROUP" -m 600 "$CASE_PRIVATE_ROOT/data/properties.json" "$tmp/properties.json"
runuser -u "$AGENT_USER" -- python3 "$tmp/license_cli.py" --socket "$sock" run-proof --feature "$FEATURE_ID" --version "$FEATURE_VERSION" --input "$tmp/properties.json" --output "$tmp/out/alone.json"
test -f "$tmp/out/alone.json"
runuser -u "$AGENT_USER" -- env PYTHONUNBUFFERED=1 python3 "$tmp/a_worker.py" "$sock" "$FEATURE_ID" "$FEATURE_VERSION" "$tmp/work" "$ready" "$pidfile" >"$tmp/a.log" 2>&1 &
for _ in $(seq 1 80); do test -s "$ready" && break; sleep .05; done
test -s "$ready"
set +e
runuser -u "$AGENT_USER" -- python3 "$tmp/license_cli.py" --socket "$sock" run-proof --feature "$FEATURE_ID" --version "$FEATURE_VERSION" --input "$tmp/properties.json" --output "$tmp/out/with-a.json"
b_rc=$?
set -e
test "$b_rc" -eq 3
python3 - "$state" "$FEATURE_ID" "$CONTROL_FEATURE" "$pidfile" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
f=sys.argv[2]; c=sys.argv[3]; pid=int(open(sys.argv[4]).read())
assert d['features'][f]==1 and d['features'][c]==1
assert any(x['feature']==f and x['owner_pid']==pid for x in d['checkouts'].values())
assert any(x['kind']=='denied' and x['feature']==f for x in d['events'])
assert not any(x['kind']=='denied' and x['feature']==c for x in d['events'])
PY
kill -TERM "$(<"$pidfile")" 2>/dev/null || true
for _ in $(seq 1 50); do test ! -d "/proc/$(<"$pidfile")" && break; sleep .05; done
test ! -d "/proc/$(<"$pidfile")"
runuser -u "$AGENT_USER" -- python3 "$tmp/license_cli.py" --socket "$sock" run-proof --feature "$FEATURE_ID" --version "$FEATURE_VERSION" --input "$tmp/properties.json" --output "$tmp/out/recovered.json"
test -s "$tmp/out/recovered.json"
python3 - "$state" "$FEATURE_ID" "$tmp/out/recovered.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert any(x['kind']=='complete' and x['feature']==sys.argv[2] and x['artifact']==sys.argv[3] and x['peer_uid']>0 for x in d['events'])
PY
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=license_seat_pool FEATURE=$FEATURE_ID CONTROL_FEATURE=$CONTROL_FEATURE REASON=exact_feature_pool_full"
