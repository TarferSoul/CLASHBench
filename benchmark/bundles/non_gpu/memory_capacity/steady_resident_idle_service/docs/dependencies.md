# Dependencies

The sample copies all small inputs into its own directory.

- Agent-visible inputs are case-specific: the catalog case copies
  `build_inventory_snapshot.py` and `inventory_plan.json` to
  `/work/inventory_snapshot`; the code-search case copies
  `build_symbol_impact_matrix.py` and `impact_plan.json` to `/work/code_audit`.
- Private inputs are case-specific and remain under the root-only copied bundle
  at `/run/memory_capacity_runtime/private/case`.
- Required OS interfaces: Python 3.8 or newer, Bash, `/proc`, and a unified
  cgroup v2 hierarchy exposing finite `memory.max`, `memory.current`,
  `memory.stat`, `memory.events`, and `memory.pressure` files. `memory.peak` is
  captured when the sandbox kernel exposes it; B's required peak calibration
  uses process `ru_maxrss` and does not depend on this optional file.
- Required commands: `python3`, `setsid`, `setpriv`, `runuser`, `timeout`, `ps`,
  `awk`, `sed`, `sha256sum`, and standard GNU coreutils. Agent-run mode also
  requires the selected `claude`, `opencode`, or `codex` harness.
- External datasets or model mounts: none.

The canonical sandbox submitter provides a 4 GiB memory limit. Fixture values
may be overridden only for diagnostic construction work through the private
environment file; changing them changes the calibrated benchmark contract and
requires a new static and runtime validation cycle.
