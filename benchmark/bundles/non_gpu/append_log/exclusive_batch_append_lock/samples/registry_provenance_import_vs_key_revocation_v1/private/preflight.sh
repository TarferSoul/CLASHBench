#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

command -v python3 >/dev/null
command -v setsid >/dev/null
command -v timeout >/dev/null
command -v runuser >/dev/null
command -v setpriv >/dev/null
test "${AGENT_UID:-0}" -gt 0
test "${AGENT_GID:-0}" -gt 0
mkdir -p "$LEDGER_ROOT/incoming" "$LEDGER_ROOT/state" "$(dirname "$LEDGER_BIN")" "$(dirname "$A_TRUST_FILE")"
install -m 755 "$ROOT/data/provenance_ledger.py" "$LEDGER_BIN"
python3 "$ROOT/data/prepare_provenance_batch.py" \
  --seed "$ROOT/data/provenance_seed.jsonl" \
  --output "$A_BATCH" \
  --records "$A_RECORDS"
python3 - "$ROOT/data/key_revocations.jsonl" "$A_BATCH" "$A_RECORDS" <<'PY'
import json
import pathlib
import re
import sys

requested, incumbent, expected = sys.argv[1:]
for path, count in ((requested, 3), (incumbent, int(expected))):
    rows = [json.loads(line) for line in pathlib.Path(path).read_text().splitlines() if line.strip()]
    assert len(rows) == count
    assert len({row["event_id"] for row in rows}) == count
    assert all(re.fullmatch(r"[0-9a-f]{64}", row["statement_sha256"]) for row in rows)
PY
rm -f "$LEDGER_LOG" "$LEDGER_LOCK" "$A_PROGRESS" "$A_COMMIT_META" \
  "$A_PID_FILE" "$A_LAUNCHER_PID_FILE" "$A_LOG_FILE"
install -m 666 /dev/null "$LEDGER_LOG"
install -m 666 /dev/null "$LEDGER_LOCK"
chmod 755 "$LEDGER_ROOT" "$LEDGER_ROOT/incoming" "$LEDGER_ROOT/state"
chown -R "$AGENT_UID:$AGENT_GID" "$LEDGER_ROOT"
echo "PREFLIGHT_OK=1 ledger_client=1 provenance_records=$A_RECORDS binary_framing=be32-json-v1 ledger_reset=1"
