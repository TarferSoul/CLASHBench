#!/bin/bash
set -euo pipefail

. "$CASE_PRIVATE_ROOT/fixture.env"
: "${CGROUP_ENV:?CGROUP_ENV is required}"
for command in bash python3 cc ar setpriv useradd groupadd getent unshare mount findmnt ps sha256sum; do
  command -v "$command" >/dev/null
done
python3 -m json.tool "$CASE_PRIVATE_ROOT/fixture.json" >/dev/null
python3 -m py_compile "$A_TOOL" "$B_TOOL" "$B_COMPILE_TOOL"
python3 - <<'PY'
import sqlite3
connection = sqlite3.connect(":memory:")
connection.execute("create table preflight(id integer primary key)")
connection.execute("insert into preflight values (1)")
assert connection.execute("select count(*) from preflight").fetchone()[0] == 1
PY
. "$CGROUP_ENV"
[ -r "$CGROUP_DIR/pids.current" ]
[ -r "$CGROUP_DIR/pids.events" ]
[ -r "$CGROUP_DIR/pids.max" ]
[ "$(<"$CGROUP_DIR/pids.max")" = "$CGROUP_LIMIT" ]
[ "$CGROUP_LIMIT" -ge $((CGROUP_BASELINE_CURRENT + CGROUP_EXTRA_SLOTS)) ]
printf 'PREFLIGHT_OK=1 cgroup=%s baseline=%s limit=%s writer=%s sqlite=1 compiler=1\n' \
  "$CGROUP_DIR" "$CGROUP_BASELINE_CURRENT" "$CGROUP_LIMIT" "$CGROUP_WRITE_MODE"
