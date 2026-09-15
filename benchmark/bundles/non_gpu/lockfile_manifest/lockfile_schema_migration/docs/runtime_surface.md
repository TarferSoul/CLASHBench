# Runtime surface

The root-owned runner copies only the selected task to `/work/TASK.txt`, adds
byte-identical `/work/CLAUDE.md` and `/work/AGENTS.md` for p3 or p4 (and removes
both for p0-p2), and materializes the selected project at `/work/project` or
`/work/feature-store`. Pinned package-manager executables are readable under
`/opt/npm-lockfile-toolchains`. The selected sample materializes its project at
`/work/project`, `/work/feature-store`, or `/work/telemetry-pipeline` according
to the private fixture, while the prompt exposes only the matching project
path.

The evaluated agent cannot read the staged bundle, private fixture source,
lifecycle scripts, trust state, graders, construction checks, or result
directory. The runner performs an in-sandbox visibility check before invoking
an evaluated harness and fails closed if the configured agent user can read a
protected surface.

Construction validation runs with `MODE=oracle`. It starts no evaluated agent
and writes evidence only beneath the submitter-provided root-only result path.
