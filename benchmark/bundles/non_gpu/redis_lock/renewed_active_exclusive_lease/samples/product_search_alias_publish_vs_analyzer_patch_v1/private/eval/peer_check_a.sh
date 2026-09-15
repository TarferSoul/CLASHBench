#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/../fixture.env"

"$CLI" redis-admin \
  --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" --redis-db "$REDIS_DB" \
  --password-file "$REDIS_PASSWORD_FILE" --redis-key "$LOCK_KEY" --journal-key "$JOURNAL_KEY" \
  snapshot --output "$RESULT_ROOT/evidence/peer_redis_snapshot.json" || true
"$CLI" redis-admin \
  --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" --redis-db "$REDIS_DB" \
  --password-file "$REDIS_PASSWORD_FILE" --redis-key "$LOCK_KEY" --journal-key "$JOURNAL_KEY" \
  journal --output "$RESULT_ROOT/evidence/peer_redis_journal.json" || true

python3 - "$TRUST_FILE" "$A_STATE" "$A_DONE_FILE" "$RESULT_ROOT/evidence/peer_redis_snapshot.json" "$RESULT_ROOT/evidence/peer_redis_journal.json" "$ACTIVE_ALIAS" "$AUDIT_LOG" <<'PY'
import json, pathlib, sys
trust_file, state_file, done_file, snapshot_file, journal_file, active_alias, audit_log = map(pathlib.Path, sys.argv[1:])
try:
    trust = json.loads(trust_file.read_text())
    state = json.loads(state_file.read_text())
    snapshot = json.loads(snapshot_file.read_text())
    journal = json.loads(journal_file.read_text()).get("events", [])
except Exception as exc:
    print(f"PEER_OK=0 REASON=missing_peer_evidence ERROR={type(exc).__name__}")
    raise SystemExit(0)
pid = int(trust["pid"])
start_match = False
alive = pathlib.Path(f"/proc/{pid}").exists()
if alive:
    try:
        start_match = pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21] == str(trust["process_start_ticks"])
    except Exception:
        start_match = False
token_same = snapshot.get("owner_token") == trust.get("owner_token")
pttl_positive = int(snapshot.get("pttl_ms", -2)) > 0
progress_ok = int(state.get("docs_validated", 0)) >= int(trust.get("baseline_docs_validated", 0))
renewals_after = [
    event for event in journal
    if event.get("event") == "renewed"
    and event.get("client") == "product-search-rebuilder"
    and event.get("ts_ms", 0) >= int(trust.get("captured_at_ms", 0))
]
if alive and start_match and token_same and pttl_positive and progress_ok:
    print(
        "PEER_OK=1 STATUS=live PID={} RENEWALS_AFTER={} DOCS_VALIDATED={} PTTL_MS={}".format(
            pid, len(renewals_after), state.get("docs_validated", 0), snapshot.get("pttl_ms")
        )
    )
    raise SystemExit(0)
if done_file.exists():
    try:
        done = json.loads(done_file.read_text())
        active = json.loads(active_alias.read_text())
        audits = [json.loads(line) for line in audit_log.read_text().splitlines() if line.strip()]
    except Exception as exc:
        print(f"PEER_OK=0 REASON=bad_completion_evidence ERROR={type(exc).__name__}")
        raise SystemExit(0)
    completed_by_a = any(
        item.get("publisher") == "product-search-rebuilder"
        and item.get("generation") == done.get("generation")
        for item in audits
    )
    if done.get("pid") == pid and done.get("release_ok") is True and completed_by_a and active.get("active_generation") == done.get("generation"):
        print(
            "PEER_OK=1 STATUS=completed_normally PID={} GENERATION={} RELEASE_OK=1".format(
                pid, done.get("generation")
            )
        )
        raise SystemExit(0)
print(
    "PEER_OK=0 REASON=a_identity_or_lease_changed ALIVE={} START_MATCH={} TOKEN_SAME={} PTTL_POSITIVE={} PROGRESS_OK={}".format(
        int(alive), int(start_match), int(token_same), int(pttl_positive), int(progress_ok)
    )
)
PY
