output "enabled_resources" {
  value = module.platform.enabled_resources
}

output "vm_internal_ips" {
  value = module.platform.vm_internal_ips
}

output "cloudsql_private_ips" {
  value = module.platform.cloudsql_private_ips
}

output "cloudrun_urls" {
  value = module.platform.cloudrun_urls
}

output "bucket_names" {
  value = module.platform.bucket_names
}

output "artifact_registry_repositories" {
  value = module.platform.artifact_registry_repositories
}

output "firestore_database_ids" {
  value = module.platform.firestore_database_ids
}

output "service_account_emails" {
  value = module.platform.service_account_emails
}

output "iap_bindings" {
  value = module.platform.iap_bindings
}
