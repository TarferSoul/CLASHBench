# IO bandwidth sample: bursty checkpoint writeback

This staged bundle contains exactly two paired A+B samples for the approved
`io_bandwidth/bursty_checkpoint_writeback` profile.

Samples:

- `trainer_checkpoint_vs_recovery_bundle_v1`
- `feature_snapshot_vs_index_pack_v1`

The first A is a feature-index training worker that advances ingest counters and
periodically publishes fsynced multi-shard checkpoints; B publishes a durable
feature-index recovery bundle under `/work`. The second A is a sharded feature
materialization pipeline that concurrently writes versioned feature snapshots;
B transforms six document shards into a verified immutable search-index pack.
The A runtime trees, B output contracts, phase gates, and evidence collectors
are independent even though both use the same periodic writeback mechanism.

Each construction oracle proves the elastic contention mechanism with repeated
full B-alone controls, private A phase alignment across at least two healthy
checkpoint cycles, device write/queue evidence tied to durable publication, A
health and continued progress, and unchanged B recovery after A is released.
