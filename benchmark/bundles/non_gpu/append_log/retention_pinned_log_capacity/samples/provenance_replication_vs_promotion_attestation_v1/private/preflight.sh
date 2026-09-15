#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

command -v python3 >/dev/null
command -v setsid >/dev/null
command -v setpriv >/dev/null
command -v runuser >/dev/null
groupadd -f provenanceops
if ! id agentb >/dev/null 2>&1; then
  useradd -m -s /bin/bash agentb
fi
usermod -a -G provenanceops agentb

rm -rf "$JOURNAL_HOME" "$RUNTIME_STATE"
mkdir -p "$STORE_ROOT" "$ARCHIVE_ROOT" "$RUNTIME_STATE" /opt/provenance-spool/bin /opt/provenance-spool/lib "$(dirname "$A_TRUST_FILE")"
install -m 755 "$ROOT/data/bounded_journal.py" "$JOURNAL_LIB"
install -m 755 "$ROOT/data/provenance-append.sh" "$JOURNAL_APPEND"
install -m 755 "$ROOT/data/provenance-replica-ack.sh" "$JOURNAL_ACK"
install -m 755 "$ROOT/data/registry_provenance_service.py" /opt/provenance-spool/lib/registry_provenance_service.py
install -m 755 "$ROOT/data/provenance_replicator.py" /opt/provenance-spool/lib/provenance_replicator.py
python3 "$JOURNAL_LIB" init --store "$STORE_ROOT" --capacity "$CAPACITY_BYTES" --segment-size "$SEGMENT_BYTES"

chgrp -R provenanceops "$JOURNAL_HOME" /opt/provenance-spool
chmod 2750 "$JOURNAL_HOME" "$ARCHIVE_ROOT" /opt/provenance-spool /opt/provenance-spool/bin /opt/provenance-spool/lib
chmod 2770 "$STORE_ROOT" "$STORE_ROOT/segments" "$ARCHIVE_ROOT"
chmod 660 "$STORE_ROOT/config.json" "$STORE_ROOT/manifest.json" "$STORE_ROOT/.append.lock"
chown -R agentb:provenanceops "$RUNTIME_STATE"
chmod 2770 "$RUNTIME_STATE"

python3 - "$B_INPUT" <<'PY'
import json
import pathlib
import sys

rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
assert len(rows) == 3
assert len({row["event_id"] for row in rows}) == 3
assert all(row["kind"] == "model_promotion_attestation" for row in rows)
assert all(len(row["signature_sha256"]) == 64 for row in rows)
assert all(len(row["evidence_merkle_proof"]) == 640 for row in rows)
PY
install -o agentb -g provenanceops -m 0640 "$B_INPUT" "$A_TARGET_INPUT"
rm -f "$A_PRODUCER_PID_FILE" "$A_SHIPPER_PID_FILE" "$A_TRUST_FILE"
echo "PREFLIGHT_OK=1 provenance_spool_initialized=1 capacity_bytes=$CAPACITY_BYTES segment_bytes=$SEGMENT_BYTES input_records=3"
