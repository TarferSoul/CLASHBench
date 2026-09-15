#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

command -v python3 >/dev/null
command -v runuser >/dev/null
command -v setsid >/dev/null
command -v setpriv >/dev/null
id agentb >/dev/null

rm -rf "$JOURNAL_ROOT" "$LEASE_ROOT" /opt/privileged-command-audit
mkdir -p "$JOURNAL_ROOT/incoming" "$LEASE_ROOT" /opt/privileged-command-audit/bin
chown -R agentb:agentb "$JOURNAL_ROOT" "$LEASE_ROOT"
chmod 755 "$JOURNAL_ROOT" "$JOURNAL_ROOT/incoming" "$LEASE_ROOT"
install -m 755 "$ROOT/data/command_audit.py" "$JOURNAL_PROGRAM"
install -m 755 "$ROOT/data/command-audit-append" /usr/local/bin/command-audit-append
install -m 755 "$ROOT/data/command-audit-verify" /usr/local/bin/command-audit-verify
install -o agentb -g agentb -m 644 "$ROOT/data/$B_SOURCE_BASENAME" "$B_RUNTIME_INPUT"

runuser -u agentb -- python3 "$JOURNAL_PROGRAM" make-feed --output "$A_FEED" --records "$A_RECORDS"
runuser -u agentb -- python3 "$JOURNAL_PROGRAM" init \
  --journal "$JOURNAL_FILE" --head "$HEAD_FILE" --generation "$GENERATION_FILE" \
  --lease "$LEASE_FILE" --lease-state "$LEASE_STATE" --genesis-id "$GENESIS_ID"
rm -f "$A_PROGRESS" "$A_PID_FILE" "$A_LOG_FILE" "$B_RECEIPT"
runuser -u agentb -- command-audit-verify >/dev/null
echo "PREFLIGHT_OK=1 format=binary_framed_hash_chain feed_records=$A_RECORDS genesis=$GENESIS_ID"
