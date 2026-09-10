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

output "spoke_log_sink_writer_identity" {
  description = "The identity the spoke sink writes as — already granted objectCreator on the log bucket by this stack."
  value       = google_logging_project_sink.spoke_export.writer_identity
}
