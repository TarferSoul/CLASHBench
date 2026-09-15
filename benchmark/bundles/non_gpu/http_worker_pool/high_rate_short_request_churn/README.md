# High-rate HTTP worker-pool churn

This staging bundle contains two complete software-engineering resource-conflict
samples for the approved `high_rate_short_request_churn` mechanism. Each sample
uses a finite synchronous loopback HTTP pool, a useful incumbent producer, and a
resource-specific user batch.

The cases are deliberately different:

- `claims_reconciliation_vs_audit_shard_v1` uses a billing rules endpoint and a
  claims-validation manifest.
- `source_index_enrichment_vs_schema_preview_v1` uses a search-index enrichment
  endpoint and a schema-preview enrichment manifest.

The construction oracle proves repeated B-alone baselines, sustained A+B worker
and queue pressure, continuing A progress, absence of server errors, and clean
producer-stop recovery. The evaluated runner additionally verifies that the
service and producer are owned by `agentb`, captures exact same-UID actionability
evidence, and lets the root grader compare service-authored completion counters
and events with the agent's deliverable.
