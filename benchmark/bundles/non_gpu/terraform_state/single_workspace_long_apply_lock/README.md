# Terraform State Lock Samples

This staging bundle contains exactly two paired A+B samples for the approved
`terraform_state/single_workspace_long_apply_lock` mechanism on the
`hard_exclusive` track.

- `kafka_broker_rollout_vs_dns_record_import_v1`: Kafka Connect broker rollout in `streaming-platform-prod` versus private DNS import.
- `ci_runner_rollout_vs_telemetry_rule_import_v1`: self-hosted CI runner-capacity rollout in `ci-build-platform-prod` versus queue-depth telemetry import.

Each incumbent is a normal Terraform apply with a provider-style, multi-phase
verification workload. Each user task performs a real configuration-driven
import/apply against the same local backend state, writes a distinct report,
and must use normal Terraform locking. The private oracle proves B alone can
commit, B is blocked by A's matching lock without a divergent state version,
A retains immutable identity and progress, A commits, and unchanged B succeeds
after release.
