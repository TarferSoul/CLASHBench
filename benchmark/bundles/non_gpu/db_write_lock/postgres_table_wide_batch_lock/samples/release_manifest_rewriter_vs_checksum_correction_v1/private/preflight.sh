#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"
test "$(id -u)" -eq 0
id "$AGENT_USER" >/dev/null
for file in \
  "$ROOT/db/runtime.sh" "$ROOT/db/init.sql" "$ROOT/a/release_manifest_rewriter.py" \
  "$ROOT/a/start_a.sh" "$ROOT/a/status_a.sh" "$ROOT/a/stop_a.sh" "$ROOT/data/b_operation.py" \
  "$ROOT/eval/capture_a_trust.sh" "$ROOT/eval/peer_check_a.sh" "$ROOT/eval/task_check_b.sh" \
  "$ROOT/oracle/conflict_oracle.sh"; do test -s "$file"; done
test "$PG_PORT" = 55432 -a "$LOCK_RELATION" = release_artifacts
echo "PREFLIGHT_OK=1 CASE=release_manifest_rewriter_vs_checksum_correction_v1"
