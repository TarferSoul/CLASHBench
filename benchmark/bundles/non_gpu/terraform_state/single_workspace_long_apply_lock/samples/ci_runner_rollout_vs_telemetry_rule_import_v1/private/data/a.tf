terraform {
  required_version = "= 1.9.8"
  backend "local" { path = "/srv/terraform-state/ci-build-platform-prod/terraform.tfstate" }
}

locals {
  workspace_name = "ci-build-platform-prod"
  runner_pool = "linux-x64-builders"
  runner_image = "ci-runner:2026.08.04.23"
  rollout_revision = "2026.08.04-runner-r23"
  runbook_url = "https://runbooks.internal/ci/runner-capacity"
  queue_threshold = 120
}

resource "terraform_data" "runner_fleet_baseline" {
  input = { workspace = local.workspace_name, pool = local.runner_pool, owner = "developer-infrastructure" }
}
resource "terraform_data" "runner_fleet_rollout" {
  input = { pool = local.runner_pool, runner_image = local.runner_image, rollout_revision = local.rollout_revision, max_parallel_jobs = 8 }
  provisioner "local-exec" {
    command = "python3 ${path.module}/ci_rollout.py --progress /var/lib/ci-runner-fleet-rollout/progress.json --output /var/lib/ci-runner-fleet-rollout --run-id runner-fleet-rollout-20260804-r23"
  }
}
output "ci_capacity_telemetry_rule_address" { value = "terraform_data.ci_capacity_telemetry_rule" }
output "ci_capacity_runbook" { value = local.runbook_url }
output "ci_queue_threshold" { value = local.queue_threshold }
