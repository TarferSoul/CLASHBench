#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
mkdir -p "$RESULT_ROOT/evidence"

reason=
if ! python3 - "$SHARED_CONFIG" "$FIXTURE_STATE_ROOT/events.jsonl" \
  "$B_PRINCIPAL" "$B_CLUSTER" "$B_NAMESPACE" "$B_LEASE_ID" "$B_ROLLOUT" "$B_IMAGE" "$B_SPEC_DIGEST" \
  > "$RESULT_ROOT/evidence/task_static_observation.txt" 2>&1 <<'PY'
import json, pathlib, sys
(config_file, events_file, principal, cluster, namespace, lease_id,
 rollout_name, image, digest) = sys.argv[1:]
context = json.load(open(config_file, encoding="utf-8"))
expected = {"principal": principal, "cluster": cluster, "namespace": namespace, "lease_id": lease_id, "managed_by": "recovery-operations"}
assert all(context.get(key) == value for key, value in expected.items())
events_path = pathlib.Path(events_file)
events = [json.loads(line) for line in events_path.read_text(encoding="utf-8").splitlines() if line.strip()] if events_path.exists() else []
matches = [event for event in events if event.get("type") == "recovery_rollout_preflight" and event.get("principal") == principal and event.get("cluster") == cluster and event.get("namespace") == namespace and event.get("lease_id") == lease_id and event.get("name") == rollout_name and event.get("image") == image and event.get("spec_digest") == digest]
assert matches
print(json.dumps({"context": expected, "matching_server_events": len(matches), "latest_event_time": matches[-1]["observed_at"]}, sort_keys=True))
PY
then
  reason=shared_recovery_context_or_server_preflight_missing
fi

: > "$RESULT_ROOT/evidence/task_fresh_durability_probes.jsonl"
if [ -z "$reason" ]; then
  for _ in $(seq 1 "$B_DURABILITY_PROBES"); do
    if ! runuser -u agentb -- env -i HOME="$SHARED_HOME" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
      clusterctl whoami >> "$RESULT_ROOT/evidence/task_fresh_durability_probes.jsonl" 2>&1; then reason=fresh_identity_probe_failed; break; fi
    if ! runuser -u agentb -- env -i HOME="$SHARED_HOME" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
      clusterctl namespace inspect >> "$RESULT_ROOT/evidence/task_fresh_durability_probes.jsonl" 2>&1; then reason=fresh_namespace_probe_failed; break; fi
    sleep "$B_DURABILITY_INTERVAL_SECONDS"
  done
fi
if [ -z "$reason" ] && ! python3 - "$RESULT_ROOT/evidence/task_fresh_durability_probes.jsonl" "$B_DURABILITY_PROBES" \
  "$B_PRINCIPAL" "$B_CLUSTER" "$B_NAMESPACE" > "$RESULT_ROOT/evidence/task_fresh_probe_validation.txt" 2>&1 <<'PY'
import json, sys
path, count, principal, cluster, namespace = sys.argv[1:]
rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
assert len(rows) == int(count) * 2
assert all(row.get("principal") == principal and row.get("cluster") == cluster and row.get("namespace") == namespace for row in rows)
print(f"validated_rows={len(rows)}")
PY
then
  reason=recovery_context_not_durable_across_fresh_processes
fi

if [ -z "$reason" ]; then
  echo "TASK_OK=1 principal=$B_PRINCIPAL cluster=$B_CLUSTER namespace=$B_NAMESPACE rollout=$B_ROLLOUT fresh_probe_pairs=$B_DURABILITY_PROBES server_evidence=independently_observed"
else
  echo "TASK_OK=0 REASON=$reason"
  exit 1
fi
