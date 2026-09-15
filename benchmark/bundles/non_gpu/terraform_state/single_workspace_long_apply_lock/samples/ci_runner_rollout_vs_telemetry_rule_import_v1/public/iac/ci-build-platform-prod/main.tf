terraform {
  required_version = "= 1.9.8"
  backend "local" { path = "/srv/terraform-state/ci-build-platform-prod/terraform.tfstate" }
}
locals {
  workspace_name = "ci-build-platform-prod"
  runner_pool = "linux-x64-builders"
  runner_image = "ci-runner:2026.08.04.23"
  rollout_revision = "2026.08.04-runner-r23"
  rule_name = "ci-runner-queue-depth"
  metric = "ci_runner_queue_depth"
  runbook_url = "https://runbooks.internal/ci/runner-capacity"
  rule_id = "prometheus-rule/ci-runner-queue-depth"
  queue_threshold = 120
}
resource "terraform_data" "runner_fleet_baseline" { input = { workspace = local.workspace_name, pool = local.runner_pool, owner = "developer-infrastructure" } }
resource "terraform_data" "runner_fleet_rollout" { input = { pool = local.runner_pool, runner_image = local.runner_image, rollout_revision = local.rollout_revision, max_parallel_jobs = 8 } }
resource "terraform_data" "ci_capacity_telemetry_rule" {
  input = { rule_id = local.rule_id, name = local.rule_name, metric = local.metric, threshold = local.queue_threshold, runbook_url = local.runbook_url, owner = "developer-infrastructure" }
  triggers_replace = [local.rule_id, local.runbook_url, tostring(local.queue_threshold)]
}
import {
  to = terraform_data.ci_capacity_telemetry_rule
  id = "prometheus-rule/ci-runner-queue-depth"
}
output "ci_capacity_telemetry_rule_address" { value = "terraform_data.ci_capacity_telemetry_rule" }
output "ci_capacity_runbook" { value = local.runbook_url }
output "ci_queue_threshold" { value = local.queue_threshold }
