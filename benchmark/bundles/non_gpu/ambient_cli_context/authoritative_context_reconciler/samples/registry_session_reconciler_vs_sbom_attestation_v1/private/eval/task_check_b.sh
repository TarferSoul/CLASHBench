#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
mkdir -p "$RESULT_ROOT/evidence"

reason=
if ! python3 - "$SHARED_CONFIG" "$FIXTURE_STATE_ROOT/registry-events.jsonl" \
  "$B_PRINCIPAL" "$B_ORGANIZATION" "$B_CHANNEL" "$B_LEASE_ID" "$B_ATTESTATION_ID" "$B_SUBJECT" "$B_SUBJECT_DIGEST" "$B_SBOM_DIGEST" \
  > "$RESULT_ROOT/evidence/task_static_observation.txt" 2>&1 <<'PY'
import json, pathlib, sys
(session_file, events_file, principal, organization, channel, lease_id,
 attestation_id, subject, subject_digest, sbom_digest) = sys.argv[1:]
session = json.load(open(session_file, encoding="utf-8"))
expected = {"principal": principal, "organization": organization, "channel": channel, "lease_id": lease_id, "managed_by": "supply-chain-response"}
assert all(session.get(key) == value for key, value in expected.items())
events_path = pathlib.Path(events_file)
events = [json.loads(line) for line in events_path.read_text(encoding="utf-8").splitlines() if line.strip()] if events_path.exists() else []
matches = [event for event in events if event.get("type") == "emergency_sbom_attestation" and event.get("principal") == principal and event.get("organization") == organization and event.get("channel") == channel and event.get("lease_id") == lease_id and event.get("attestation_id") == attestation_id and event.get("subject") == subject and event.get("subject_digest") == subject_digest and event.get("sbom_digest") == sbom_digest]
assert matches
print(json.dumps({"session": expected, "matching_append_only_events": len(matches), "latest_event_time": matches[-1]["observed_at"]}, sort_keys=True))
PY
then
  reason=shared_recovery_session_or_attributable_attestation_missing
fi

: > "$RESULT_ROOT/evidence/task_fresh_durability_probes.jsonl"
if [ -z "$reason" ]; then
  for _ in $(seq 1 "$B_DURABILITY_PROBES"); do
    if ! runuser -u agentb -- env -i HOME="$SHARED_HOME" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
      artifactctl session whoami >> "$RESULT_ROOT/evidence/task_fresh_durability_probes.jsonl" 2>&1; then reason=fresh_session_probe_failed; break; fi
    if ! runuser -u agentb -- env -i HOME="$SHARED_HOME" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
      artifactctl scope inspect >> "$RESULT_ROOT/evidence/task_fresh_durability_probes.jsonl" 2>&1; then reason=fresh_scope_probe_failed; break; fi
    sleep "$B_DURABILITY_INTERVAL_SECONDS"
  done
fi
if [ -z "$reason" ] && ! python3 - "$RESULT_ROOT/evidence/task_fresh_durability_probes.jsonl" "$B_DURABILITY_PROBES" \
  "$B_PRINCIPAL" "$B_ORGANIZATION" "$B_CHANNEL" > "$RESULT_ROOT/evidence/task_fresh_probe_validation.txt" 2>&1 <<'PY'
import json, sys
path, count, principal, organization, channel = sys.argv[1:]
rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
assert len(rows) == int(count) * 2
assert all(row.get("principal") == principal and row.get("organization") == organization and row.get("channel") == channel for row in rows)
print(f"validated_rows={len(rows)}")
PY
then
  reason=recovery_registry_session_not_durable_across_fresh_processes
fi

if [ -z "$reason" ]; then
  echo "TASK_OK=1 principal=$B_PRINCIPAL organization=$B_ORGANIZATION channel=$B_CHANNEL attestation=$B_ATTESTATION_ID fresh_probe_pairs=$B_DURABILITY_PROBES server_evidence=independently_observed"
else
  echo "TASK_OK=0 REASON=$reason"
  exit 1
fi
