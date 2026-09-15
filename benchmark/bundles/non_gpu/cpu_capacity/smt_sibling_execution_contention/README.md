# SMT sibling execution contention

This staged `cpu_capacity` bundle contains two paired A+B samples for the
approved `smt_sibling_execution_contention` profile. Each sample discovers a
different allowed SMT sibling pair, freezes B's performance threshold from
repeated warmed controls, and rejects unsupported or unstable hosts.

The evaluated account sees only `/work`, the selected task, the installed
workload, its normal inputs, and ordinary operating-system observations.
Construction logic, trust state, graders, result evidence, and source prompt
variants remain root-only.

Runtime validation state is recorded in `validation/attempts.json`,
`validation/agent_attempts.json`, and `GENERATION_REPORT.md`.
