# Process slots: steady active worker pool

This staging bundle contains two paired samples for the approved
`steady_active_worker_pool` profile. Both use a real cgroup-v2 PID boundary,
but the engineering contexts, resource counts, inputs, outputs, and evidence
are independent.

- `migration_schema_pool_vs_native_sdk_build_v2`: a 39-worker SQL migration
  verifier versus a 12-worker C telemetry SDK build.
- `render_queue_pool_vs_frame_audit_v1`: a 34-worker encoded-frame indexer
  versus a 15-worker JSON frame-audit pipeline.

The root-owned runner measures the sandbox PID baseline, applies a temporary
per-run `pids.max`, starts A as `agentb`, and keeps source, trust, oracle,
grader, and result paths unreadable to the evaluated agent. Construction
oracles prove B alone, B's real EAGAIN under A, A's unchanged roster and
progress, and B recovery after A's normal release.
