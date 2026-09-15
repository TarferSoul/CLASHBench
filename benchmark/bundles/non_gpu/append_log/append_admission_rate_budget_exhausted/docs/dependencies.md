# Dependencies

Both samples use only Python 3 and standard Linux utilities included in the
canonical `cbreal:latest` images (`bash`, `runuser`, `setpriv`, `ps`,
`df`, and `free`). Python code uses only the standard library.

No host paths, datasets, package caches, model files, or network services are
mounted into the sandbox. Each sample materializes its own bounded fixtures at
runtime. The selected B client and input fixtures are copied into `/work` and
are intentionally visible to `agentb`; collector state, durable logs, A trust,
oracle evidence, and benchmark source are not.

The runner accepts `HOST_ARTIFACT_ROOT` from the sandbox submitter for root-only
result collection. No task dependency or runtime credential is configurable by
the evaluated user.
