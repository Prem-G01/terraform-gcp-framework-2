output "github_environments_json" {
  description = "Set this JSON as repository variable ENVIRONMENTS_JSON. These identifiers are not credentials."
  value = jsonencode({
    callgenie = {
      wif_provider    = google_iam_workload_identity_pool_provider.github.name
      tf_plan_sa      = google_service_account.plan.email
      tf_apply_sa     = google_service_account.apply.email
      state_bucket    = google_storage_bucket.shared_history.name
      artifact_bucket = google_storage_bucket.shared_history.name
      state_prefix    = local.state_prefix
      artifact_prefix = local.artifact_prefix
      logging_prefix  = local.logging_prefix
      history_prefix  = var.history_prefix
    }
  })
}

output "history_bucket" { value = google_storage_bucket.shared_history.name }
output "logging_sink" { value = google_logging_project_sink.central_history.name }

output "history_prefix" { value = var.history_prefix }

output "vm_monitoring_service_account" { value = google_service_account.vm_monitoring.email }
