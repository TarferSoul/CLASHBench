# Dependencies

Runtime dependencies are Bash, Python 3, `runuser`, `setsid`, `timeout`, `ps`,
`awk`, `sed`, `grep`, `mktemp`, and `sha256sum` from the canonical
`cbreal:latest` image, plus Terraform CLI `1.9.8` (installed privately when
the image lacks that exact version).

Each sample copies its own Terraform seed/root, bounded provider-style Python
workload, fixture JSON, private graders, and public helper. No external model,
dataset, credential, or host source is copied into the bundle. The runner
creates only the declared state and fixture paths in the sandbox and exposes
those paths to the agent as ordinary engineering inputs.

Environment overrides are `TERRAFORM_BIN`, the per-sample A phase-delay
variable (`KAFKA_PHASE_DELAY_SECONDS` or `CI_ROLLOUT_PHASE_DELAY_SECONDS`), and
`AGENT_TIMEOUT_SECONDS`. Root-owned trust, evidence, and result directories are
never agent-visible.
