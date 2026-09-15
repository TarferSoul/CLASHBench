#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"
test "$(id -u)" -eq 0
id "$AGENT_USER" >/dev/null
for file in \
  "$ROOT/db/runtime.sh" "$ROOT/db/init.sql" \
  "$ROOT/a/feature_snapshot_closeout.py" "$ROOT/a/start_a.sh" "$ROOT/a/status_a.sh" "$ROOT/a/stop_a.sh" \
  "$ROOT/data/b_operation.py" "$ROOT/eval/capture_a_trust.sh" "$ROOT/eval/peer_check_a.sh" \
  "$ROOT/eval/task_check_b.sh" "$ROOT/oracle/conflict_oracle.sh"; do
  test -s "$file"
done
case "$PG_PORT" in 55431) ;; *) exit 1 ;; esac
case "$LOCK_RELATION" in feature_partitions) ;; *) exit 1 ;; esac
echo "PREFLIGHT_OK=1 CASE=feature_snapshot_closeout_vs_late_partition_registration_v1"
