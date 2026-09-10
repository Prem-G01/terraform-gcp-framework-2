output "state_bucket" {
  value = google_storage_bucket.state.name
}

output "artifact_bucket" {
  value = google_storage_bucket.artifacts.name
}

output "log_bucket" {
  value = google_storage_bucket.logs.name
}

output "state_backend_config_hint" {
  description = "Copy-paste for `terraform init` in environments/<env>/."
  value       = "terraform init -backend-config=\"bucket=${google_storage_bucket.state.name}\" -backend-config=\"prefix=<env>\""
}

output "log_sink_source_project" {
  description = "Which project's logs are being exported (null if create_log_sink = false)."
  value       = var.create_log_sink ? local.log_source_project_id : null
}

output "log_sink_writer_identity" {
  description = "The identity the sink writes as — already granted objectCreator on the log bucket by this stack. null if create_log_sink = false."
  value       = var.create_log_sink ? google_logging_project_sink.export[0].writer_identity : null
}
