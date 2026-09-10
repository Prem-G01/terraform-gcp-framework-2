# This file is intentionally ~10 lines and will stay that way for every
# environment (see environments/dev, environments/sit — byte-for-byte the
# same shape, only the defaults in variables.tf and the backend prefix in
# versions.tf differ). All real resource logic lives in ../../platform,
# which knows nothing about "saafe" — see docs/architecture.md.

module "platform" {
  source = "../../platform"

  project_id      = var.project_id
  environment     = var.environment
  deployment_file = "${path.module}/.generated/deployment.normalized.json"
}
