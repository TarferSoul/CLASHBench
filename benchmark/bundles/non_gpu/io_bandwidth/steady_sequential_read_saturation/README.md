# IO Bandwidth: Steady Sequential Read Saturation

This staged bundle contains exactly two paired A+B samples for the approved
`io_bandwidth/steady_sequential_read_saturation` mechanism.

- `checkpoint_audit_vs_model_shard_load_smoke_v1`: a model-registry integrity
  audit contends with a complete candidate checkpoint load and tensor smoke.
- `index_scrub_vs_checkpoint_read_audit_v1`: a supervised search-segment scrub
  worker set contends with a parallel direct-read checkpoint readiness audit.

Both cases use independent immutable file trees on the same physical device,
supported direct I/O, fixed repeated-control thresholds, device telemetry,
semantic integrity checks, healthy incumbent progress, and post-release
throughput recovery. The benchmark track is `elastic_contention`.
