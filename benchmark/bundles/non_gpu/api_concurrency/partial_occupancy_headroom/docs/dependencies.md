# Dependencies

Both samples use only Python 3 standard-library modules plus normal Linux tools
already present in the canonical `cbreal:latest` images: `bash`, `curl`,
`setpriv`, `runuser`, `ps`, and `/proc`.

Each sample is self-contained.  Private gateway/incumbent code and private
grader/oracle inputs are copied to root-only runtime paths.  Public fixtures and
one task-specific Python client are copied into `/work` and are intentionally
agent-visible.  No host models, datasets, caches, mounts, external API keys, or
inherited proxy settings are required by the benchmark workload.

Construction uses the pinned `SANDBOX_IMAGE` from
`benchmark_final/sandbox_test.env`.  Agent validation uses the pinned
`SANDBOX_AGENT_IMAGE`; the GLM-5.2 relay credential is supplied only by the
root-owned evaluator and is never part of this bundle.

