output "github_environments_json" {
  description = "Set this JSON as repository variable ENVIRONMENTS_JSON. These identifiers are not credentials."
  value = jsonencode({
    callgenie = {
      wif_provider    = google_iam_workload_identity_pool_provider.github.name
      tf_plan_sa      = google_service_account.plan.email
      tf_apply_sa     = google_service_account.apply.email
      state_bucket    = google_storage_bucket.state.name
      artifact_bucket = google_storage_bucket.artifacts.name
    }
  })
}
