# Nontransactional dirty-version gate samples

This staged bundle contains two paired A+B samples for the approved
`db_migration_chain/nontransactional_dirty_version_gate` mechanism.

- `audit_event_concurrent_indexes_vs_retention_api_v1`: an online audit-event
  index rollout gates the following retention-query migration.
- `feature_snapshot_reindex_vs_ingest_guard_v1`: an online feature-store index
  rebuild gates the following ingestion-guard migration.

The root-owned runner starts an isolated PostgreSQL cluster and the incumbent
migration as `agentb`, exposes only the normal migration CLI and database
surface, and keeps all fixtures, graders, trust state, source prompts, and
runtime results private.
