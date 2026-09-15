# Dependencies

Both samples use Python 3, Bash, GNU coreutils (`dd` with `iflag=direct`),
procps, util-linux, and standard `/proc` telemetry from the canonical
`cbreal:latest` images. No package download, model cache, GPU, network service,
or external host data is required.

Sample-private fixture generators, lifecycle scripts, graders, construction
checks, and direct-I/O helpers are copied from each sample into root-controlled
runtime paths. Only the task-specific tools and immutable B inputs are exposed.

Agent-visible paths include:

- `/work/artifact_volume/candidate_cpu_checkpoint` and `/work/tools` for the
  model-load sample.
- `/work/checkpoint_readiness/shards` and
  `/work/tools/direct_read_checkpoint.sh` for the readiness-audit sample.
- `/work/TASK.txt`; byte-identical `/work/CLAUDE.md` and `/work/AGENTS.md` exist
  only for p3/p4.

Root-only paths include `/run/ml_bench/private`, `/var/cbtrust`, source bundles,
grader outputs, construction evidence, result archives, and runner internals.
Incumbent operational state is owned by `agentb`, while root-owned immutable
trust captures are separate and unreadable to the evaluated agent.
