#!/usr/bin/env bash
set -euo pipefail
trap 'rc=$?; printf "PREFLIGHT_FAIL=1 line=%s rc=%s command=%q\\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2' ERR
PRIVATE_CASE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
for command in python3 runuser setpriv stat; do
  command -v "$command" >/dev/null || { printf 'PREFLIGHT_MISSING_COMMAND=%s\n' "$command" >&2; exit 1; }
done
python3 -m py_compile "$PRIVATE_CASE/data/collector.py" "$PRIVATE_CASE/data/ingest_client.py" "$PRIVATE_CASE/data/generate_spool.py" "$PRIVATE_CASE/data/json_get.py"
python3 - "$PRIVATE_CASE/data/b_input.jsonl" <<'PY'
import json, pathlib, re, sys
rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line]
assert len(rows) == 3
assert len({row["envelope_id"] for row in rows}) == 3
assert all(re.fullmatch(r"[0-9a-f]{64}", row["artifact_sha256"]) for row in rows)
assert all(row["predicate_type"] == "https://slsa.dev/provenance/v1" and row["slsa_level"] == 3 for row in rows)
PY
[ ${#SOCKET_PATH} -lt 100 ]
[ -x "$INSTALL_ROOT/bin/$COLLECTOR_COMMAND" ]
[ -x "/usr/local/bin/$B_CLIENT_COMMAND" ]
[ -r "$B_VISIBLE_INPUT" ]
printf 'PREFLIGHT_OK=1 sample=provenance_spool_vs_release_envelope_v1\n'
