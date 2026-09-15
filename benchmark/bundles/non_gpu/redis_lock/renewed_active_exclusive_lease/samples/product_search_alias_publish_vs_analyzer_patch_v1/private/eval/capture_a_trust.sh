#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/../fixture.env"

mkdir -p "$TRUST_ROOT"
chmod 700 "$TRUST_ROOT"
"$CLI" redis-admin \
  --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" --redis-db "$REDIS_DB" \
  --password-file "$REDIS_PASSWORD_FILE" --redis-key "$LOCK_KEY" --journal-key "$JOURNAL_KEY" \
  snapshot --output "$RESULT_ROOT/evidence/capture_a_redis_snapshot.json"
"$CLI" redis-admin \
  --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" --redis-db "$REDIS_DB" \
  --password-file "$REDIS_PASSWORD_FILE" --redis-key "$LOCK_KEY" --journal-key "$JOURNAL_KEY" \
  journal --output "$RESULT_ROOT/evidence/capture_a_redis_journal.json"

python3 - "$A_PID_FILE" "$A_STATE" "$RESULT_ROOT/evidence/capture_a_redis_snapshot.json" "$RESULT_ROOT/evidence/capture_a_redis_journal.json" "$TRUST_FILE" <<'PY'
import json, pathlib, sys
pid_file, state_file, snapshot_file, journal_file, trust_file = map(pathlib.Path, sys.argv[1:])
pid = int(pid_file.read_text().strip())
state = json.loads(state_file.read_text())
snapshot = json.loads(snapshot_file.read_text())
journal = json.loads(journal_file.read_text()).get("events", [])
if not snapshot.get("owner_token"):
    raise SystemExit("A trust capture found no Redis owner token")
renewals = [event for event in journal if event.get("event") == "renewed" and event.get("client") == "product-search-rebuilder"]
payload = {
    "pid": pid,
    "process_start_ticks": pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21],
    "phase": state.get("phase"),
    "baseline_docs_validated": int(state.get("docs_validated", 0)),
    "baseline_renewals": int(state.get("renewals", 0)),
    "baseline_segment_merge_counter": int(state.get("segment_merge_counter", 0)),
    "owner_token": snapshot["owner_token"],
    "pttl_ms": int(snapshot.get("pttl_ms", -1)),
    "renewal_events": len(renewals),
    "captured_at_ms": max([event.get("ts_ms", 0) for event in journal] or [0]),
}
trust_file.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
print(
    "TRUST_CAPTURED=1 PID={} TOKEN_LEN={} PTTL_MS={} RENEWALS={} DOCS_VALIDATED={}".format(
        pid, len(payload["owner_token"]), payload["pttl_ms"], payload["renewal_events"], payload["baseline_docs_validated"]
    )
)
PY
chmod 600 "$TRUST_FILE"
