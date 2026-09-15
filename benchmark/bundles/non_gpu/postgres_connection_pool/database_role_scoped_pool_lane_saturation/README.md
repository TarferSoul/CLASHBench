# PostgreSQL Connection Pool Sample

This staged bundle contains exactly two distinct paired A+B samples for the
approved `database_role_scoped_pool_lane_saturation` profile.

- `release_contract_runner_vs_migration_rehearsal_v1`: a release schema
  contract runner fills the `release_shadow` / `release_runner` lane while a
  four-worker migration rehearsal requires the same endpoint and role.
- `feature_parity_validator_vs_embedding_export_v1`: an ML feature-store
  parity validator fills the `feature_lab` / `feature_validator` lane while a
  five-exporter embedding feature export requires that exact lane.

Each fixture uses a fresh local PostgreSQL instance behind PgBouncer. The
oracle proves exact-lane B-alone completion, target-lane queueing and bounded
admission failure with productive A still healthy, global PostgreSQL headroom,
a healthy control lane, no lock blocker, and recovery after normal A release.
The evaluated harness and the actual resource-holding A process both run as
`agentb`; the runner archives a same-UID actionability probe before the agent.

Validation must be performed in fresh PJLab sandboxes with the canonical
`cbreal:latest` mapping from `benchmark_final/sandbox_test.env`.
