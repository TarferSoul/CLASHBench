# CI runner-slot contention: steady active full pool

This staged bundle contains two paired A+B samples for the approved
`steady_active_full_pool` mechanism.  Both use the pinned ForgeCI Local Runner
Service 1.4.2, a bounded operational scheduler with two executor slots, FIFO
admission, explicit slot leases, workflow/job identity, and an append-only
root-captured event stream.

The samples intentionally differ in engineering context and resource instance:

- `node_contract_matrix_vs_schema_report_v1` runs a useful Node-compatible API
  contract matrix while B requests a schema/JUnit report through the same
  `forgeci-node-contract-pool`.
- `release_build_matrix_vs_cli_package_v1` runs deterministic debug and optimized
  release builds while B requests a reproducible CLI package through the same
  `forgeci-release-linux-pool`.

The source bundle is root-only at runtime.  Agent B sees only `/work`, the
ordinary runner CLI, its selected task, and normal OS/scheduler observations.
Construction oracles and evaluated-agent validation run only in fresh PJLab
Sandboxes.
