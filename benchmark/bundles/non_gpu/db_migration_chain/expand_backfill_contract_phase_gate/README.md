# Expand-backfill-contract phase-gate samples

This staged bundle contains two paired A+B samples for the approved
`db_migration_chain/expand_backfill_contract_phase_gate` mechanism. Each sample
uses a distinct canonical SQLite database, resumable production-style backfill,
contract DDL, and independent root-owned evidence.

Executable workload validation is restricted to fresh PJLab Sandboxes. The
bundle runner fails closed unless `BENCHMARK_SANDBOX=1` is supplied by the
Sandbox control plane.
