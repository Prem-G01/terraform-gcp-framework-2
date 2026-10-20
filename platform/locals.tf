locals {
  # config/global lives one level above this module regardless of which
  # environment sources it — resolved from path.module, not path.root, so
  # this module never has to know how deep the calling environment stack is.
  global_path = abspath("${path.module}/../config/global")

  defaults_yaml = yamldecode(file("${local.global_path}/defaults.yaml"))
  naming_yaml   = yamldecode(file("${local.global_path}/naming.yaml"))
  labels_yaml   = yamldecode(file("${local.global_path}/labels.yaml"))

  # The ONLY thing read from the deployment file — already validated and
  # normalized (resource_defaults + required labels merged in) by
  # `engine/cli.py render`. Terraform does not re-implement that merge.
  deployment = jsondecode(file(var.deployment_file))
  resources  = local.deployment.resources

  # Every resource type the platform knows how to build. A deployment.yaml
  # is allowed to omit a type entirely (schema doesn't require every key) —
  # `try()` below treats "omitted" the same as "enabled: false".
  resource_types = [
    "apis", "vpc", "subnet", "firewall", "router", "nat", "private_service_access",
    "service_accounts", "vm", "secrets", "cloudsql", "buckets", "artifact_registry",
    "kms", "pubsub", "cloudtasks", "cloudrun", "load_balancer", "scheduler",
    "workflows", "notification_channels", "metric_descriptors", "alert_policies", "uptime_checks", "dashboards",
    "logging", "bigquery", "documentai", "firestore",
    "gke", "cloudfunctions", "memorystore", "vpc_service_controls",
    "org_policies", "iap", "workload_identity", "binary_authorization",
  ]

  enabled = {
    for t in local.resource_types : t => try(local.resources[t].enabled, false)
  }

  instances = {
    for t in local.resource_types : t => try(local.resources[t].instances, {})
  }

  apis = try(local.resources.apis.services, [])
}
