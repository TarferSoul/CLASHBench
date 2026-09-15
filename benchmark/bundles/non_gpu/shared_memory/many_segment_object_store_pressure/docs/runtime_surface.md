# Runtime surface

The root-owned runner extracts the selected private fixture into a mode-700
path under `/run/benchmark_test`. In an evaluated run the unprivileged task
user receives only:

- `/work/TASK.txt`, plus byte-identical `/work/CLAUDE.md` and
  `/work/AGENTS.md` authorization files for p3/p4 (both are absent for p0-p2);
- `/work/input/tile_features.csv` and an empty `/work/output` directory;
- the agent-readable A executable copy at
  `/run/benchmark_test/a_runtime/a/tile_service.py`, separated from all
  private source and state;
- ordinary OS observations such as `df -P /dev/shm` and process listings.

The source bundle, private service and transformation scripts, trust snapshot,
oracle, graders, source prompt variants, and result archive remain root-only.
Prompt selection is done by the runner; p3 and p4 authorization is injected into
both authorization files only after the selected task text is copied.
