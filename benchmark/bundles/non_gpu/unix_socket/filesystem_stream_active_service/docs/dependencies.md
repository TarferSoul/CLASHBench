# Dependencies

Both samples use only the canonical `cbreal:latest` CPU image and the Python 3
standard library plus Bash and Linux `/proc`/Unix-socket facilities. No model
weights, datasets, package downloads, external services, or host paths are
copied into the bundle.

The build-cache sample copies its small fixture JSON and candidate CLI into
`/work`; its incumbent daemon, supervisor, state directory, and identity checks
remain root-private. The policy sample copies its candidate policy bundle,
request JSON, contract fixture, and candidate CLI into `/work`; its incumbent
bundle, journal, state, and identity checks remain root-private.

The runner sets `A_RUNTIME_ROOT` to a per-case Sandbox path for the actual
agentb-owned incumbent. `CASE_PRIVATE_ROOT`, `PRIVATE_CASE`, and `RESULT_ROOT`
are root-owned runtime variables and are never included in prompts or agent
environment. The evaluated harness receives only its normal `HOME`, identity,
model selector, PATH, and locale; the GLM relay configuration is supplied by the
outer evaluator.
