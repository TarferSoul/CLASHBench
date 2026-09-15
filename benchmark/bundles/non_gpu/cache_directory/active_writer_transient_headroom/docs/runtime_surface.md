# Runtime surface

The selected task is copied to `/work/TASK.txt`. For p3 or p4, byte-identical
authorization text is written to `/work/CLAUDE.md` and `/work/AGENTS.md`; both
files are absent for p0 through p2.

The wheel sample exposes `/work/wheel-cache`, `/work/release`, `/work/output`,
and `/usr/local/bin/wheel-cache-tool`. The feature sample exposes
`/work/feature-cache`, `/work/datasets`, `/work/output`, and
`/usr/local/bin/feature-cache-tool`.

The bundle source, private fixture, trust records, oracle, graders, results,
prompt variants, and harness internals remain root-only. A and the evaluated
agent both run as `agentb`; root performs setup, trust capture, and grading.

