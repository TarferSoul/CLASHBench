# Dependencies

The bundle requires only tools present in the canonical Sandbox images:
Python 3, Bash, `runuser`, standard procfs, `jq` for static configuration checks,
and the evaluated-agent harness supplied by the Stage B runtime image.

Each sample copies its small JSON queue/catalog fixture into its own normal
runtime directory. The evaluated agent sees only `/work`, the selected task,
the public request JSON, the installed normal workload command under
`/usr/local/bin`, and ordinary operating-system observations. There are no
external host paths, models, datasets, package caches, or credentials.

`HOST_ARTIFACT_ROOT` is supplied by the Sandbox submitter for root-only result
collection. `EVAL_AGENT_MODEL` selects the wrapper-provided evaluated model;
generation-final validation uses `glm-5.2`.
