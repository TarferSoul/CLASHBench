# Pipe-throughput steady writer backpressure

This staging bundle contains exactly two paired A+B samples for the approved
`steady_state_writer_backpressure` profile. Each incumbent is a useful,
same-UID producer that publishes fixed-size framed records to a real named
pipe consumed by a continuously healthy local service. The user task is a
concrete recovery or release-engineering replay through that same pipe.

The construction oracle repeats B-alone controls, records the FIFO device and
inode, pipe capacity and occupancy, consumer drain, writer blocking, accepted
record IDs, and A progress, then proves B recovers with the unchanged consumer
after A is stopped cleanly. The evaluated run uses p0 with OpenCode and
GLM-5.2; task and peer outcomes remain independent of runtime validity.

Samples:

- `ci_event_publisher_vs_recovery_replay_v2`: a CI event publisher feeds a
  receipt-producing collector while B replays a recovery event set.
- `media_segmenter_vs_manifest_replay_v1`: a live media segmenter feeds a
  packaging daemon while B submits a checksummed release manifest.

