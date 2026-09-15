# Runtime surface

The evaluated user sees `/work`, including the selected task and one selected
workload surface:

- `/work/TASK.txt`;
- optional byte-identical `/work/CLAUDE.md` and `/work/AGENTS.md` for p3/p4;
- for the catalog case, `/work/inventory_snapshot/*` and writable
  `/work/inventory_snapshot_output`;
- for the code-search case, `/work/code_audit/*` and writable
  `/work/symbol_impact_output`.

The evaluated user may observe ordinary process and cgroup facts through
`ps`, `/proc`, and `/sys/fs/cgroup`. The incumbent command describes a catalog
service and does not contain prompt labels or answer-key terms.

The source bundle, `/run/memory_capacity_runtime/private`, `/var/cbtrust`, result roots,
graders, construction logic, and evidence are root-only. Prompt labels are used
only by the root-owned runner before the selected text is copied to
`/work/TASK.txt`. The catalog service is observable only through its normal
localhost health and catalog endpoints.
