output "enabled_resources" {
  description = "Which resource types this deployment actually created, for quick inspection (`terraform output enabled_resources`)."
  value       = { for k, v in local.enabled : k => v if v }
}

output "vpc_self_links" {
  value = try(module.vpc[0].self_links, {})
}

output "subnet_self_links" {
  value = try(module.subnet[0].self_links, {})
}

output "service_account_emails" {
  value = try(module.service_accounts[0].emails, {})
}

output "vm_internal_ips" {
  value = try(module.vm[0].internal_ips, {})
}

output "cloudsql_private_ips" {
  value = try(module.cloudsql[0].private_ips, {})
}

output "firestore_database_ids" {
  value = try(module.firestore[0].database_ids, {})
}

output "bucket_names" {
  value = try(module.buckets[0].bucket_names, {})
}

output "artifact_registry_repositories" {
  value = try(module.artifact_registry[0].repositories, {})
}

output "cloudrun_urls" {
  value = try(module.cloudrun[0].urls, {})
}

output "load_balancer_ip_addresses" {
  value = try(module.load_balancer[0].ip_addresses, {})
}

output "pubsub_topics" {
  value = try(module.pubsub[0].topics, {})
}

output "kms_crypto_keys" {
  value     = try(module.kms[0].crypto_keys, {})
  sensitive = false
}

output "bigquery_datasets" {
  value = try({ for k, v in local.instances.bigquery : k => k }, {})
}

output "gke_cluster_endpoints" {
  value = try(module.gke[0].endpoints, {})
}

output "cloudfunctions_urls" {
  value = try(module.cloudfunctions[0].urls, {})
}

output "memorystore_hosts" {
  value = try(module.memorystore[0].hosts, {})
}

output "vpc_service_controls_perimeters" {
  value = try(module.vpc_service_controls[0].perimeter_names, {})
}

output "org_policies_enforced" {
  value = try(module.org_policies[0].enforced_constraints, [])
}

output "iap_bindings" {
  value = try(module.iap[0].bindings, {})
}

output "workload_identity_bindings" {
  value = try(module.workload_identity[0].bindings, {})
}

output "binary_authorization_evaluation_mode" {
  value = try(module.binary_authorization[0].evaluation_mode, null)
}

output "notification_channel_names" {
  value = try(module.notification_channels[0].channels, {})
}

output "alert_policy_names" {
  value = try(module.alert_policies[0].alert_policies, {})
}

output "uptime_check_names" {
  value = try(module.uptime_checks[0].uptime_checks, {})
}

output "monitoring_dashboard_ids" {
  value = try(module.dashboards[0].dashboards, {})
}
