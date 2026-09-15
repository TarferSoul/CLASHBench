# ci-build-platform-prod Terraform root

This root manages the linux-x64-builders runner pool and its telemetry state in
`/srv/terraform-state/ci-build-platform-prod/terraform.tfstate`.

The existing queue-depth rule is visible at
`/srv/telemetry-rules/ci-runner-queue-depth.json`. Use normal Terraform locking.
The helper validates the root, imports the rule, applies the SLO annotation,
and writes `/work/ci_telemetry_import_report.json`.
