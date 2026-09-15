# lockfile_manifest: exclusive_dependency_transaction

This staged bundle contains two distinct paired A+B samples for the curated
`exclusive_dependency_transaction` profile.

Sample `feature_pipeline_schema_refresh_vs_ingest_retry_v1` uses a local Python
feature-pipeline workspace. A refreshes the schema worker while holding the
transaction lease; B adds an ingest retry client through the normal coordinator.

Sample `model_registry_manifest_refresh_vs_batch_sampler_v1` uses a separate
model-registry workspace and lock instance. A validates model-card manifests;
B adds a batch sampler to the evaluation worker and produces a batch report.
Both projects have two service manifests feeding one root `requirements.lock`,
and both use an inode-backed `flock(2)` lease before any publication.

The bundle preserves the profile's `hard_exclusive` benchmark track and merges
the workspace root-lockfile fan-in and two-file transaction-window variants as
scope and oracle-hardening details of the same independent mechanism.
