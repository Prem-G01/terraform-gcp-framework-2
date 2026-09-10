output "enabled_resources" {
  value = module.platform.enabled_resources
}

output "bucket_names" {
  value = module.platform.bucket_names
}

output "cloudrun_urls" {
  value = module.platform.cloudrun_urls
}

output "service_account_emails" {
  value = module.platform.service_account_emails
}
