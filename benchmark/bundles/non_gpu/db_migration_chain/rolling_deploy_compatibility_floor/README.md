# Rolling-deploy database compatibility-floor samples

This staged bundle contains exactly two paired A+B samples for the approved
`db_migration_chain/rolling_deploy_compatibility_floor` mechanism.

- `telemetry_ingest_legacy_tags_contract_v1`: an old telemetry ingestion replica
  continues writing a legacy JSON tag column while B must finalize normalized
  tags and remove that column.
- `model_observability_legacy_view_contract_v1`: an old observability report
  service continuously queries a compatibility view while B must finalize typed
  latency rollups and remove the legacy view/text representation.

Both fixtures use real SQLite databases, live process-backed compatibility
membership, monotonically advancing useful work, same-UID actionability, and
root-owned schema/process graders. Runtime workloads are Sandbox-only.
