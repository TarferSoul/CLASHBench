#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
OUT=${1:-$B_OUTPUT_DIR}
MANIFEST=${2:-$B_MANIFEST}
set +e
summary=$(python3 - "$OUT" "$MANIFEST" "$PG_DATABASE" "$PG_SCHEMA" "$B_DB_USER" "$B_WORKERS" "$B_REQUIRED_SESSIONS" <<'PY'
import hashlib,json,pathlib,sys
out,manifest,database,schema,role,workers,required=sys.argv[1:]
out=pathlib.Path(out); workers=int(workers)
try:
    data=json.loads(pathlib.Path(manifest).read_text())
    assert data.get('completed') is True, 'not_completed'
    assert data.get('database')==database and data.get('schema')==schema and data.get('role')==role, 'dsn_contract_wrong'
    assert int(data.get('workers'))==workers, 'workers_wrong'
    assert int(data.get('required_session_cohort'))==int(required), 'cohort_wrong'
    releases=data.get('completed_releases') or []
    assert len(releases)==workers, 'release_count_wrong'
    checks=data.get('checksums') or {}
    for release in range(1,workers+1):
        name=f'release_{release:02d}.csv'; path=out/name
        assert path.is_file(), f'missing:{name}'
        lines=path.read_text().splitlines()
        assert len(lines)==24, f'row_count:{name}'
        assert checks.get(name)==hashlib.sha256(path.read_bytes()).hexdigest(), f'checksum:{name}'
    print(f'OK releases={len(releases)} checksums={len(checks)}')
except Exception as exc:
    print(f'INVALID {type(exc).__name__}:{exc}')
    raise SystemExit(1)
PY
)
rc=$?
set -e
if [ "$rc" = 0 ]; then
  echo "TASK_OK=1 RESOURCE=postgres_connection_pool DATABASE=$PG_DATABASE SCHEMA=$PG_SCHEMA WORKERS=$B_WORKERS ${summary#OK }"
else
  detail=$(printf '%s' "$summary" | tr '\n' ' ' | tr -c 'A-Za-z0-9_./:=-' '_')
  echo "TASK_OK=0 REASON=reconciliation_matrix_missing_or_invalid DETAIL=$detail"
  exit 1
fi
