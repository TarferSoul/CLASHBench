# Bursty FIFO tail-latency samples

This staged bundle contains exactly two paired A+B samples for the approved
`pipe_throughput/bursty_writer_tail_latency` mechanism.

- `node_diagnostics_vs_priority_alerts_v1` runs a Linux node-diagnostics
  exporter whose periodic acknowledged flush competes with a three-alert
  on-call delivery request on `/work/diagnostics_bus/ingest.fifo`.
- `build_telemetry_vs_release_audit_v1` runs a build-stage telemetry exporter
  whose stage-boundary flush competes with a four-record release-audit request
  on `/work/telemetry_router/ingest.fifo`.

Both samples preserve the elastic-contention track. Their private construction
oracles establish repeated B-alone latency, trigger joint trials from observed
high-occupancy A flushes, correlate B tail latency with real FIFO occupancy,
writer blocking, collector drain, and completed A flushes, then prove recovery
after A stops normally.
