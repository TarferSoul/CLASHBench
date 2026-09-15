# Dependencies

- Python 3 standard library for all workload, gateway, receiver, and grading
  logic.
- Bash, `runuser`, `timeout`, `ps`, and ordinary procfs/sysfs utilities
  from the canonical Sandbox image.
- `tc` is used only to archive the loopback qdisc state; the deterministic
  directional rate policy is enforced by the root-started egress gateway.
- No host path, model, dataset, package cache, or external service is mounted.
- The installed A runtime programs live under `/opt/egress-lane/<sample>`.
  The public B client and specification are copied into `/work`.
- `A_STATE_ROOT`, `A_TRUST_PATH`, `INSTALL_ROOT`, and `RESULT_ROOT` are private
  runner overrides. They are not placed in prompts or agent configuration.
