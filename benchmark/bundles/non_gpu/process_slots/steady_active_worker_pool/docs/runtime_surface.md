# Runtime surface

The submitter uploads the bundle into a root-only source directory. The runner
copies only the selected task and normal task inputs into `/work`, starts A and
the evaluated harness as `agentb`, and exposes ordinary `/proc` and cgroup
observations.

Agent-visible paths include `/work/TASK.txt`, optional byte-identical
`/work/CLAUDE.md` and `/work/AGENTS.md` for p3/p4, the selected read-only
engineering inputs, writable B output, and normal OS observations.

The uploaded bundle, private fixture, trust capture, actionability record,
oracles, graders, cgroup restoration state, result evidence, and source prompt
variants remain root-only. Prompt selection occurs in the packaged runner and
copies only the chosen prompt text to `/work/TASK.txt`.
