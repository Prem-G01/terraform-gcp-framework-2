# =============================================================================
# Bootstrap — run ONCE per project, manually, before any environment stack
# can use a remote backend. See docs/state-management.md.
#
# NOT applied as part of this rebuild (kept code-only per the decision
# recorded in docs/troubleshooting.md "What this rebuild did not do") — a
# human with org-level IAM permissions runs `terraform apply` here
# deliberately, reviews the plan, and records the resulting bucket names
# and service-account emails in each environments/<env>/versions.tf
# backend-config comment.
#
# Every environment gets its OWN tf-plan-<env>/tf-apply-<env> pair, all
# hosted in this project (var.project_id) — a single compromised or
# misconfigured environment's deploy identity can never touch another
# environment's resources. var.home_environment (default "dev") is the one
# environment whose real GCP project IS var.project_id, so its pair's
# project-level roles are granted right here. Every other environment
# (sit/uat/prod, typically separate projects) gets its pair's roles from
# bootstrap/grants/ instead — a small stack applied once per spoke project
# by whoever owns IAM there. See docs/service-accounts.md.
# =============================================================================

module "deploy_roles" {
  source = "../modules/iam/deploy_roles"
}

locals {
  required_apis = [
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
    "logging.googleapis.com",
  ]

  # Cartesian product of environment x role, keyed for a stable for_each.
  home_apply_role_bindings = {
    for role in module.deploy_roles.apply_sa_roles :
    role => role
  }
  home_plan_role_bindings = {
    for role in module.deploy_roles.plan_sa_roles :
    role => role
  }
}

resource "google_project_service" "bootstrap_apis" {
  for_each = toset(local.required_apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# --- Remote state bucket ----------------------------------------------------
# Every environment's Terraform state lives here, centrally, under
# -backend-config="prefix=<env>" — including sit/uat/prod's, even though
# those environments' actual GCP resources live in other projects.

resource "google_storage_bucket" "state" {
  project  = var.project_id
  name     = var.state_bucket_name
  location = var.region

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  # Holds real per-environment state files -- must never be force-deleted
  # by a routine `terraform destroy`. The 2026-08-25 teardown flipped this
  # true temporarily; reverted to false now that bootstrap is being
  # recreated for real use.
  force_destroy = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions         = 1
      days_since_noncurrent_time = var.state_bucket_retention_days
    }
    action {
      type = "Delete"
    }
  }

  soft_delete_policy {
    retention_duration_seconds = 7 * 24 * 60 * 60
  }

  depends_on = [google_project_service.bootstrap_apis]
}

# --- CI/CD artifact bucket (validation.json / plan.json / plan.txt) --------

resource "google_storage_bucket" "artifacts" {
  project  = var.project_id
  name     = var.artifact_bucket_name
  location = var.region

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  # Reverted to false now that bootstrap is being recreated for real use
  # (was temporarily true for the 2026-08-25 teardown).
  force_destroy = false

  lifecycle_rule {
    condition {
      age = 180
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.bootstrap_apis]
}

# --- Centralized log bucket ------------------------------------------------
# Destination for every environment's Cloud Logging export, kept in this
# project rather than each spoke project — logs outlive the source
# project's own lifecycle and stay out of reach of anyone whose access is
# scoped to just one environment. var.home_environment's sink is wired up
# directly below (same project, one apply). Every other environment's sink
# lives in bootstrap/grants/<that project>/ instead, and its writer
# identity is granted access here via var.log_sink_writer_identities — see
# docs/logging.md "Centralized logging" for the two-step reason why.

resource "google_storage_bucket" "logs" {
  project  = var.project_id
  name     = var.log_bucket_name
  location = var.region

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  # Holds real exported log data -- reverted to false now that bootstrap is
  # being recreated for real use (was temporarily true for the 2026-08-25
  # teardown).
  force_destroy = false

  lifecycle_rule {
    condition {
      age = var.log_bucket_retention_days
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.bootstrap_apis]
}

resource "google_logging_project_sink" "home_environment" {
  project     = var.project_id
  name        = "central-log-export-${var.home_environment}"
  destination = "storage.googleapis.com/${google_storage_bucket.logs.name}"
  # No filter — every log entry in this project. Narrow this per-project
  # in bootstrap/grants/ if a spoke project only wants a subset exported.
  filter                 = ""
  unique_writer_identity = true

  depends_on = [google_project_service.bootstrap_apis]
}

resource "google_storage_bucket_iam_member" "home_environment_sink_writes_logs" {
  bucket = google_storage_bucket.logs.name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.home_environment.writer_identity
}

resource "google_storage_bucket_iam_member" "spoke_sinks_write_logs" {
  for_each = var.log_sink_writer_identities

  bucket = google_storage_bucket.logs.name
  role   = "roles/storage.objectCreator"
  member = each.value
}

# --- CI/CD service accounts, one pair per environment -----------------------

resource "google_service_account" "terraform_plan" {
  for_each = toset(var.environments)

  project      = var.project_id
  account_id   = "tf-plan-${each.key}"
  display_name = "Terraform Plan (${each.key}, read-only)"
  description  = "Runs `terraform plan` for the ${each.key} environment in CI/CD. Never has write access — see docs/service-accounts.md."

  depends_on = [google_project_service.bootstrap_apis]
}

resource "google_service_account" "terraform_apply" {
  for_each = toset(var.environments)

  project      = var.project_id
  account_id   = "tf-apply-${each.key}"
  display_name = "Terraform Apply (${each.key})"
  description  = "Runs `terraform apply` for the ${each.key} environment in CI/CD after manual approval — see docs/cicd.md. Roles granted here only for var.home_environment; every other environment's roles come from bootstrap/grants/ in that environment's own project."

  depends_on = [google_project_service.bootstrap_apis]
}

resource "google_project_iam_member" "home_plan_roles" {
  for_each = local.home_plan_role_bindings

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.terraform_plan[var.home_environment].email}"
}

resource "google_project_iam_member" "home_apply_roles" {
  for_each = local.home_apply_role_bindings

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.terraform_apply[var.home_environment].email}"
}

# Every environment's SA needs access to the shared state/artifact buckets
# (that's centrally hosted regardless of where the environment's actual
# resources live) — scoped by IAM condition to just that environment's own
# object prefix, so e.g. a compromised sit identity can't read prod's
# Terraform state.

resource "google_storage_bucket_iam_member" "plan_reads_state" {
  for_each = toset(var.environments)

  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.terraform_plan[each.key].email}"

  condition {
    title      = "${each.key}-state-only"
    expression = "resource.name.startsWith(\"projects/_/buckets/${var.state_bucket_name}/objects/${each.key}/\")"
  }
}

resource "google_storage_bucket_iam_member" "apply_manages_state" {
  for_each = toset(var.environments)

  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.terraform_apply[each.key].email}"

  condition {
    title      = "${each.key}-state-only"
    expression = "resource.name.startsWith(\"projects/_/buckets/${var.state_bucket_name}/objects/${each.key}/\")"
  }
}

resource "google_storage_bucket_iam_member" "plan_writes_artifacts" {
  for_each = toset(var.environments)

  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.terraform_plan[each.key].email}"

  condition {
    title      = "${each.key}-artifacts-only"
    expression = "resource.name.startsWith(\"projects/_/buckets/${var.artifact_bucket_name}/objects/deployments/${each.key}/\")"
  }
}

resource "google_storage_bucket_iam_member" "apply_writes_artifacts" {
  for_each = toset(var.environments)

  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.terraform_apply[each.key].email}"

  condition {
    title      = "${each.key}-artifacts-only"
    expression = "resource.name.startsWith(\"projects/_/buckets/${var.artifact_bucket_name}/objects/deployments/${each.key}/\")"
  }
}

# --- Workload Identity Federation (optional, off by default) --------------
# Avoids a long-lived service-account JSON key for CI/CD, per docs/service-
# accounts.md. Requires var.github_repository ("<org>/<repo>") when
# enabled. attribute.environment maps to the GitHub Actions `environment:`
# OIDC claim, which GitHub only stamps onto a token once that environment's
# required reviewers have approved the run — so tf-apply-prod can only ever
# be assumed from a job actually running under the "prod" GitHub
# Environment, not just from the right repository.

resource "google_iam_workload_identity_pool" "cicd" {
  count = var.enable_workload_identity_federation ? 1 : 0

  project                   = var.project_id
  workload_identity_pool_id = "cicd-pool"
  display_name              = "CI/CD"
  description               = "Federated identity for the Terraform plan/apply service accounts — no SA keys."
}

resource "google_iam_workload_identity_pool_provider" "github" {
  count = var.enable_workload_identity_federation ? 1 : 0

  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.cicd[0].workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub Actions"

  attribute_mapping = {
    "google.subject"        = "assertion.sub"
    "attribute.repository"  = "assertion.repository"
    "attribute.environment" = "assertion.environment"
  }

  attribute_condition = "assertion.repository == \"${var.github_repository}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "plan_wif_binding" {
  for_each = var.enable_workload_identity_federation ? toset(var.environments) : []

  service_account_id = google_service_account.terraform_plan[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.cicd[0].name}/attribute.repository/${var.github_repository}"
}

resource "google_service_account_iam_member" "apply_wif_binding" {
  for_each = var.enable_workload_identity_federation ? toset(var.environments) : []

  service_account_id = google_service_account.terraform_apply[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.cicd[0].name}/attribute.environment/${each.key}"
}
