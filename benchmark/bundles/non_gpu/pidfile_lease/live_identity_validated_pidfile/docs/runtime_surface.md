# Runtime surface

The evaluated user sees `/work/TASK.txt`, the selected input fixture in `/work`,
the installed normal command (`/usr/local/bin/code-indexer` or
`/usr/local/bin/release-relay`), and ordinary OS observations. The runner also
exposes the canonical PID-file path because it is the normal service surface.

The bundle source, private fixtures, trust records, graders, observer output,
result directories, prompt sources, and evaluator internals remain root-only.
The runner checks these paths and executes the same-UID actionability probe
before starting the evaluated harness. For p3 and p4 it creates byte-identical
`/work/CLAUDE.md` and `/work/AGENTS.md`; it removes both for p0-p2.
