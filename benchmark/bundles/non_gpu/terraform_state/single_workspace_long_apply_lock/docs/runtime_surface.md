# Runtime Surface

The evaluated agent sees only `/work/TASK.txt`, the selected public Terraform
root under `/work/iac`, `/usr/local/bin/terraform`, the sample's disposable
state directory, and its normal input fixture:

- Kafka sample: `/work/iac/streaming-platform-prod`, `/srv/terraform-state/streaming-platform-prod`, `/srv/dns-records/kafka-bootstrap.internal.json`.
- CI sample: `/work/iac/ci-build-platform-prod`, `/srv/terraform-state/ci-build-platform-prod`, `/srv/telemetry-rules/ci-runner-queue-depth.json`.

For p3/p4 the runner creates byte-identical `/work/CLAUDE.md` and
`/work/AGENTS.md`. Source bundles, private fixtures, graders, trust state,
runner code, and result artifacts stay root-only; visibility is checked inside
the sandbox before A or the agent starts.
