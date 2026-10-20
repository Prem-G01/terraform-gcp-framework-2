# =============================================================================
# Platform orchestration root
# -----------------------------------------------------------------------------
# One module block per resource TYPE the platform supports — this is the
# bounded "resource type registry" a static Terraform graph requires (see
# docs/architecture.md "Why not fully dynamic resource kinds"). Each block
# is gated by `count = local.enabled.<type> ? 1 : 0`, driven entirely by
# resources.<type>.enabled in the deployment file — a disabled type creates
# nothing and leaves nothing in state. Cross-module references use
# `try(module.x[0].output, {})` so a disabled upstream module never breaks
# plan for a module that happens to still be enabled.
# =============================================================================

module "labels" {
  source = "../modules/shared/labels"
  labels = merge(local.defaults_yaml.labels_defaults, { environment = var.environment })
}

module "tags" {
  source = "../modules/shared/tags"
  tags   = try(local.labels_yaml.tags.default, [])
}

module "naming" {
  source       = "../modules/shared/naming"
  organization = local.defaults_yaml.organization
  naming       = local.naming_yaml.naming
  environment  = var.environment
  instance_keys = {
    vm  = keys(local.instances.vm)
    sql = keys(local.instances.cloudsql)
  }
}

module "apis" {
  count      = local.enabled.apis ? 1 : 0
  source     = "../modules/apis"
  project_id = var.project_id
  apis       = local.apis
}

module "vpc" {
  count      = local.enabled.vpc ? 1 : 0
  source     = "../modules/networking/vpc"
  project_id = var.project_id
  config     = { vpcs = local.instances.vpc }
  depends_on = [module.apis]
}

module "subnet" {
  count      = local.enabled.subnet ? 1 : 0
  source     = "../modules/networking/subnet"
  project_id = var.project_id
  config     = { subnets = local.instances.subnet }
  vpcs       = try(module.vpc[0].self_links, {})
  depends_on = [module.vpc]
}

module "firewall" {
  count      = local.enabled.firewall ? 1 : 0
  source     = "../modules/networking/firewall"
  project_id = var.project_id
  config     = { firewalls = local.instances.firewall }
  vpcs       = try(module.vpc[0].self_links, {})
  depends_on = [module.vpc, module.subnet]
}

module "router" {
  count      = local.enabled.router ? 1 : 0
  source     = "../modules/networking/router"
  project_id = var.project_id
  config     = { routers = local.instances.router }
  vpcs       = try(module.vpc[0].self_links, {})
  depends_on = [module.apis, module.vpc]
}

module "nat" {
  count      = local.enabled.nat ? 1 : 0
  source     = "../modules/networking/nat"
  project_id = var.project_id
  config     = { nats = local.instances.nat }
  routers    = try(module.router[0].routers, {})
  depends_on = [module.router]
}

module "private_service_access" {
  count      = local.enabled.private_service_access ? 1 : 0
  source     = "../modules/networking/private_service_access"
  project_id = var.project_id
  config     = { private_service_access = local.instances.private_service_access }
  networks   = try(module.vpc[0].self_links, {})
  depends_on = [module.vpc, module.apis]
}

module "service_accounts" {
  count      = local.enabled.service_accounts ? 1 : 0
  source     = "../modules/iam/service_accounts"
  project_id = var.project_id
  config     = { service_accounts = local.instances.service_accounts }
  depends_on = [module.apis]
}

module "vm" {
  count            = local.enabled.vm ? 1 : 0
  source           = "../modules/compute/vm"
  project_id       = var.project_id
  config           = { vms = local.instances.vm }
  subnets          = try(module.subnet[0].self_links, {})
  service_accounts = try(module.service_accounts[0].emails, {})
  generated_names  = try(module.naming.generated_names.vm, {})
  depends_on = [
    module.apis, module.vpc, module.subnet, module.firewall, module.nat, module.service_accounts,
  ]
}

module "secrets" {
  count      = local.enabled.secrets ? 1 : 0
  source     = "../modules/security/secrets"
  project_id = var.project_id
  config     = { secrets = local.instances.secrets }
  depends_on = [module.apis]
}

module "cloudsql" {
  count           = local.enabled.cloudsql ? 1 : 0
  source          = "../modules/database/cloudsql"
  project_id      = var.project_id
  config          = { cloudsql = local.instances.cloudsql }
  vpcs            = try(module.vpc[0].self_links, {})
  passwords       = try(module.secrets[0].passwords, {})
  generated_names = try(module.naming.generated_names.sql, {})
  depends_on      = [module.apis, module.vpc, module.private_service_access, module.secrets]
}

module "firestore" {
  count      = local.enabled.firestore ? 1 : 0
  source     = "../modules/database/firestore"
  project_id = var.project_id
  config     = { firestore = local.instances.firestore }
  depends_on = [module.apis]
}

module "buckets" {
  count      = local.enabled.buckets ? 1 : 0
  source     = "../modules/storage/buckets"
  project_id = var.project_id
  config     = { buckets = local.instances.buckets }
  depends_on = [module.apis]
}

module "artifact_registry" {
  count      = local.enabled.artifact_registry ? 1 : 0
  source     = "../modules/artifact_registry"
  project_id = var.project_id
  config     = { artifact_registry = local.instances.artifact_registry }
  depends_on = [module.apis]
}

module "kms" {
  count      = local.enabled.kms ? 1 : 0
  source     = "../modules/security/kms"
  project_id = var.project_id
  config     = { kms = local.instances.kms }
  depends_on = [module.apis]
}

module "pubsub" {
  count      = local.enabled.pubsub ? 1 : 0
  source     = "../modules/messaging/pubsub"
  project_id = var.project_id
  config     = { pubsub = local.instances.pubsub }
  kms_keys   = try(module.kms[0].crypto_keys, {})
  depends_on = [module.apis, module.kms]
}

module "cloudtasks" {
  count      = local.enabled.cloudtasks ? 1 : 0
  source     = "../modules/messaging/cloudtasks"
  project_id = var.project_id
  config     = { cloudtasks = local.instances.cloudtasks }
  depends_on = [module.apis]
}

module "cloudrun" {
  count            = local.enabled.cloudrun ? 1 : 0
  source           = "../modules/compute/cloudrun"
  project_id       = var.project_id
  config           = { cloudrun = local.instances.cloudrun }
  service_accounts = try(module.service_accounts[0].emails, {})
  vpcs             = try(module.vpc[0].self_links, {})
  subnets          = try(module.subnet[0].self_links, {})
  depends_on       = [module.apis, module.service_accounts, module.nat]
}

module "load_balancer" {
  count             = local.enabled.load_balancer ? 1 : 0
  source            = "../modules/networking/load_balancer"
  project_id        = var.project_id
  config            = { load_balancer = local.instances.load_balancer }
  cloudrun_services = try(module.cloudrun[0].service_names, {})
  depends_on        = [module.apis, module.cloudrun]
}

module "scheduler" {
  count            = local.enabled.scheduler ? 1 : 0
  source           = "../modules/orchestration/scheduler"
  project_id       = var.project_id
  config           = { scheduler = local.instances.scheduler }
  service_accounts = try(module.service_accounts[0].emails, {})
  depends_on       = [module.apis, module.cloudrun, module.service_accounts]
}

module "workflows" {
  count            = local.enabled.workflows ? 1 : 0
  source           = "../modules/orchestration/workflows"
  project_id       = var.project_id
  config           = { workflows = local.instances.workflows }
  service_accounts = try(module.service_accounts[0].emails, {})
  depends_on = [
    module.apis, module.service_accounts, module.scheduler, module.pubsub,
    module.cloudtasks, module.cloudrun,
  ]
}

module "notification_channels" {
  count      = local.enabled.notification_channels ? 1 : 0
  source     = "../modules/monitoring/notification_channels"
  project_id = var.project_id
  config     = { notification_channels = local.instances.notification_channels }
  depends_on = [module.apis]
}

module "metric_descriptors" {
  count      = local.enabled.metric_descriptors ? 1 : 0
  source     = "../modules/monitoring/metric_descriptors"
  project_id = var.project_id
  config     = { metric_descriptors = local.instances.metric_descriptors }
  depends_on = [module.apis]
}

module "dashboards" {
  count      = local.enabled.dashboards ? 1 : 0
  source     = "../modules/monitoring/dashboards"
  project_id = var.project_id
  config     = { dashboards = local.instances.dashboards }
  depends_on = [module.apis]
}

module "alert_policies" {
  count                 = local.enabled.alert_policies ? 1 : 0
  source                = "../modules/monitoring/alert_policies"
  project_id            = var.project_id
  config                = { alert_policies = local.instances.alert_policies }
  notification_channels = try(module.notification_channels[0].channels, {})
  depends_on            = [module.notification_channels, module.metric_descriptors, module.vm, module.cloudsql]
}

module "uptime_checks" {
  count      = local.enabled.uptime_checks ? 1 : 0
  source     = "../modules/monitoring/uptime_checks"
  project_id = var.project_id
  config     = { uptime_checks = local.instances.uptime_checks }
  depends_on = [module.apis]
}

module "logging" {
  count      = local.enabled.logging ? 1 : 0
  source     = "../modules/monitoring/logging"
  project_id = var.project_id
  config     = { logging = local.instances.logging }
  depends_on = [module.apis]
}

module "bigquery" {
  count      = local.enabled.bigquery ? 1 : 0
  source     = "../modules/analytics/bigquery"
  project_id = var.project_id
  config     = { bigquery = local.instances.bigquery }
  depends_on = [module.apis]
}

module "documentai" {
  count      = local.enabled.documentai ? 1 : 0
  source     = "../modules/ai/documentai"
  project_id = var.project_id
  config     = { documentai = local.instances.documentai }
  depends_on = [module.apis]
}

module "gke" {
  count                       = local.enabled.gke ? 1 : 0
  source                      = "../modules/compute/gke"
  project_id                  = var.project_id
  config                      = { gke = local.instances.gke }
  vpcs                        = try(module.vpc[0].self_links, {})
  subnets                     = try(module.subnet[0].self_links, {})
  service_accounts            = try(module.service_accounts[0].emails, {})
  enable_binary_authorization = local.enabled.binary_authorization
  depends_on                  = [module.apis, module.vpc, module.subnet, module.service_accounts]
}

module "cloudfunctions" {
  count            = local.enabled.cloudfunctions ? 1 : 0
  source           = "../modules/compute/cloudfunctions"
  project_id       = var.project_id
  config           = { cloudfunctions = local.instances.cloudfunctions }
  service_accounts = try(module.service_accounts[0].emails, {})
  depends_on       = [module.apis, module.service_accounts]
}

module "memorystore" {
  count      = local.enabled.memorystore ? 1 : 0
  source     = "../modules/database/memorystore"
  project_id = var.project_id
  config     = { memorystore = local.instances.memorystore }
  vpcs       = try(module.vpc[0].self_links, {})
  depends_on = [module.apis, module.vpc, module.private_service_access]
}

module "vpc_service_controls" {
  count                     = local.enabled.vpc_service_controls ? 1 : 0
  source                    = "../modules/security/vpc_service_controls"
  project_id                = var.project_id
  config                    = { vpc_service_controls = local.instances.vpc_service_controls }
  organization_id           = try(local.resources.vpc_service_controls.organization_id, "")
  create_access_policy      = try(local.resources.vpc_service_controls.create_access_policy, false)
  existing_access_policy_id = try(local.resources.vpc_service_controls.existing_access_policy_id, "")
  depends_on                = [module.apis]
}

# --- Zero-trust: org policy, IAP access, workload identity, binary auth ---

module "org_policies" {
  count      = local.enabled.org_policies ? 1 : 0
  source     = "../modules/security/org_policies"
  project_id = var.project_id

  disable_service_account_key_creation = try(local.resources.org_policies.disable_service_account_key_creation, true)
  restrict_vm_external_ips             = try(local.resources.org_policies.restrict_vm_external_ips, true)
  restrict_public_sql_ips              = try(local.resources.org_policies.restrict_public_sql_ips, true)
  require_os_login                     = try(local.resources.org_policies.require_os_login, true)
  skip_default_network_creation        = try(local.resources.org_policies.skip_default_network_creation, true)

  depends_on = [module.apis]
}

module "iap" {
  count      = local.enabled.iap ? 1 : 0
  source     = "../modules/security/iap"
  project_id = var.project_id
  config     = local.instances.iap
  vm_names   = try(module.vm[0].names, {})
  vm_zones   = try(module.vm[0].zones, {})
  depends_on = [module.apis, module.vm]
}

module "workload_identity" {
  count               = local.enabled.workload_identity ? 1 : 0
  source              = "../modules/security/workload_identity"
  project_id          = var.project_id
  config              = local.instances.workload_identity
  service_account_ids = try(module.service_accounts[0].ids, {})
  depends_on          = [module.apis, module.service_accounts, module.gke]
}

module "binary_authorization" {
  count      = local.enabled.binary_authorization ? 1 : 0
  source     = "../modules/security/binary_authorization"
  project_id = var.project_id

  evaluation_mode               = try(local.resources.binary_authorization.evaluation_mode, "ALWAYS_DENY")
  require_attestations_by       = try(local.resources.binary_authorization.require_attestations_by, [])
  enforcement_mode              = try(local.resources.binary_authorization.enforcement_mode, "ENFORCED_BLOCK_AND_AUDIT_LOG")
  global_policy_evaluation_mode = try(local.resources.binary_authorization.global_policy_evaluation_mode, "ENABLE")

  depends_on = [module.apis]
}
