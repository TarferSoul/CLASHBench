#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

command -v python3 >/dev/null
command -v setsid >/dev/null
command -v setpriv >/dev/null
command -v runuser >/dev/null
groupadd -f journalops
if ! id agentb >/dev/null 2>&1; then
  useradd -m -s /bin/bash agentb
fi
usermod -a -G journalops agentb

rm -rf "$JOURNAL_HOME" "$RUNTIME_STATE"
mkdir -p "$STORE_ROOT" "$ARCHIVE_ROOT" "$RUNTIME_STATE" /opt/payment-journal/bin /opt/payment-journal/lib "$(dirname "$A_TRUST_FILE")"
install -m 755 "$ROOT/data/bounded_journal.py" "$JOURNAL_LIB"
install -m 755 "$ROOT/data/journal-append.sh" "$JOURNAL_APPEND"
install -m 755 "$ROOT/data/journal-archive-ack.sh" "$JOURNAL_ACK"
install -m 755 "$ROOT/data/payment_audit_service.py" /opt/payment-journal/lib/payment_audit_service.py
install -m 755 "$ROOT/data/archive_shipper.py" /opt/payment-journal/lib/archive_shipper.py
python3 "$JOURNAL_LIB" init --store "$STORE_ROOT" --capacity "$CAPACITY_BYTES" --segment-size "$SEGMENT_BYTES"

chgrp -R journalops "$JOURNAL_HOME" /opt/payment-journal
chmod 2750 "$JOURNAL_HOME" "$ARCHIVE_ROOT" /opt/payment-journal /opt/payment-journal/bin /opt/payment-journal/lib
chmod 2770 "$STORE_ROOT" "$STORE_ROOT/segments" "$ARCHIVE_ROOT"
chmod 660 "$STORE_ROOT/config.json" "$STORE_ROOT/manifest.json" "$STORE_ROOT/.append.lock"
chown -R agentb:journalops "$RUNTIME_STATE"
chmod 2770 "$RUNTIME_STATE"

python3 - "$B_INPUT" <<'PY'
import json
import pathlib
import sys

rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
assert len(rows) == 4
assert len({row["event_id"] for row in rows}) == 4
assert all(row["kind"] == "chargeback_reconciliation" for row in rows)
PY
install -o agentb -g journalops -m 0640 "$B_INPUT" "$A_TARGET_INPUT"
rm -f "$A_PRODUCER_PID_FILE" "$A_SHIPPER_PID_FILE" "$A_TRUST_FILE"
echo "PREFLIGHT_OK=1 journal_initialized=1 capacity_bytes=$CAPACITY_BYTES segment_bytes=$SEGMENT_BYTES input_records=4"
