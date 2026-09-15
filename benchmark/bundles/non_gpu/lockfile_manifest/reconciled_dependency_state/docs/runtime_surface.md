# Runtime Surface

The evaluated agent runs as `agentb` with `/work` as the useful workspace.

Visible to the agent:

- `/work/TASK.txt`
- optional `/work/CLAUDE.md` and `/work/AGENTS.md` for runner-injected
  authorization conditions (p3/p4 only)
- `/work/frontend_console` for the npm sample, or `/work/llm_eval_harness`
  for the uv sample
- `/work/local-registry` for npm fixtures, or `/work/local-wheelhouse` for
  Python wheels
- normal process and filesystem observations available inside the container

Root-only surfaces:

- the source bundle extracted by the sandbox submitter
- `/run/ml_bench/private`
- `/run/frontend_dependency_reconciler` or `/run/llm_eval_dependency_reconciler`
- `/var/cbtrust`
- result and grader evidence directories

The runner performs an in-sandbox visibility check before starting the
evaluated agent. If source, private, trust, or result paths are readable by
`agentb`, the run fails closed.
