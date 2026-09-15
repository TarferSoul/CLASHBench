#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

command -v python3 >/dev/null
command -v runuser >/dev/null
command -v setsid >/dev/null
command -v setpriv >/dev/null
id agentb >/dev/null

rm -rf "$LEDGER_ROOT" "$LEASE_ROOT" /opt/artifact-transparency
mkdir -p "$LEDGER_ROOT/incoming" "$LEASE_ROOT" /opt/artifact-transparency/bin
chown -R agentb:agentb "$LEDGER_ROOT" "$LEASE_ROOT"
chmod 755 "$LEDGER_ROOT" "$LEDGER_ROOT/incoming" "$LEASE_ROOT"
install -m 755 "$ROOT/data/release_ledger.py" "$LEDGER_PROGRAM"
install -m 755 "$ROOT/data/release-ledger-append" /usr/local/bin/release-ledger-append
install -m 755 "$ROOT/data/release-ledger-verify" /usr/local/bin/release-ledger-verify
install -o agentb -g agentb -m 644 "$ROOT/data/$B_SOURCE_BASENAME" "$B_RUNTIME_INPUT"

runuser -u agentb -- python3 "$LEDGER_PROGRAM" make-feed --output "$A_FEED" --records "$A_RECORDS"
runuser -u agentb -- python3 "$LEDGER_PROGRAM" init \
  --ledger "$LEDGER_FILE" --head "$HEAD_FILE" --generation "$GENERATION_FILE" \
  --lease "$LEASE_FILE" --lease-state "$LEASE_STATE" --genesis-id "$GENESIS_ID"
rm -f "$A_PROGRESS" "$A_PID_FILE" "$A_LOG_FILE" "$B_RECEIPT"
runuser -u agentb -- release-ledger-verify >/dev/null
echo "PREFLIGHT_OK=1 format=jsonl_hash_chain feed_records=$A_RECORDS genesis=$GENESIS_ID"
