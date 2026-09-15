# Dotenv critical-key value exclusivity

This staged bundle contains two paired A+B samples for the approved
`critical_key_value_exclusivity` dotenv profile. Each sample exercises a live
engineering workload that reloads one canonical dotenv document and a B task
that must install an incompatible effective value for the same critical key.

The samples are self-contained. Runtime source, fixture, oracle, trust, grading,
and result surfaces remain root-owned; only the selected task and ordinary
workload files are copied to `/work` for the evaluated `agentb` user.

Runtime validation uses fresh PJLab Sandboxes only. See `GENERATION_REPORT.md`
and the normalized ledgers under `validation/` for exact attempt evidence.
