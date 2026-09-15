#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"
command -v mysql >/dev/null
command -v mysqld >/dev/null
command -v runuser >/dev/null
/usr/bin/python3 -c 'import pymysql'
for script in a/start_a.sh a/status_a.sh a/stop_a.sh data/apply_serving_lookup_index.sh eval/capture_a_trust.sh eval/check_actionability.sh eval/peer_check_a.sh eval/task_check_b.sh oracle/conflict_oracle.sh; do [ -x "$ROOT/$script" ]; done
mysql --protocol=socket --socket="$MYSQL_SOCKET" --user=root --skip-password --batch --skip-column-names --execute "SELECT COUNT(*) FROM $LIVE_DB.$TARGET_TABLE WHERE publication_id='$PUBLICATION_ID'" | grep -qx "$TARGET_ROW_COUNT"
mysql --protocol=socket --socket="$MYSQL_SOCKET" --user=root --skip-password --batch --skip-column-names --execute "SELECT COUNT(*) FROM $CONTROL_DB.$TARGET_TABLE WHERE publication_id='$PUBLICATION_ID'" | grep -qx "$TARGET_ROW_COUNT"
echo "PREFLIGHT_OK=1 SAMPLE=$SAMPLE_ID LIVE_DB=$LIVE_DB CONTROL_DB=$CONTROL_DB ROWS=$TARGET_ROW_COUNT"
