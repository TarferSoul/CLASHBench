# Network Bandwidth: Bulk Transfer Queueing Latency Pressure

This bundle contains exactly two paired samples for the approved
`network_bandwidth/bulk_transfer_queueing_latency_pressure` profile.

Samples:

- `pg_basebackup_vs_migration_readiness_v1`: A PostgreSQL disaster-recovery
  base-backup publisher streams checksum-tagged segments to a remote backup
  gateway through a bounded queued TCP path. B asks the evaluated agent to run a
  latency-bound migration-readiness transaction against the same control plane.
- `ci_cache_replication_vs_metadata_probe_v1`: A CI content-addressed-cache
  mirror copies large verified blobs through a bounded queued path. B asks the
  evaluated agent to complete a 100-key cache metadata and ETag readiness sweep
  under its latency contract.

The scarce resource in both cases is finite link service rate plus queued-byte
capacity. B transfers only small control requests, but those request bytes wait
behind A's sustained useful bulk transfer and miss the declared latency SLO
while the remote application remains healthy. The resource instances, A
workloads, B deliverables, and evidence thresholds are intentionally distinct.

Runtime validation must use `BENCHMARK_SANDBOX=1` through the repository PJLab
sandbox submitters. The runner refuses direct host execution and runs the
resource holder and evaluated harness as `agentb`.
