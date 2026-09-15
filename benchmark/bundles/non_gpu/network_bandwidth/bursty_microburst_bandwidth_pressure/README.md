# Bursty network bandwidth pressure

This staged bundle contains two paired A+B samples for the approved
`bursty_microburst_bandwidth_pressure` profile.

- `checkpoint_fanout_vs_ci_toolchain_v1`: a distributed-training checkpoint
  publisher fans out four verified shards at every save boundary. B publishes a
  checksum-pinned CI toolchain through the same 512 kbit gateway path.
- `log_segment_shipper_vs_release_manifest_v1`: a telemetry shipper flushes
  three sealed segments at every rotation boundary. B atomically publishes a
  two-part schema release envelope through a separate 640 kbit ingestion path.

Each construction oracle records repeated B-alone results, multiple
phase-aligned A+B trials, high-resolution loopback and qdisc or shared-shaper
counters, receiver commits, immutable A identity/progress, and repeated recovery
after A is released.

