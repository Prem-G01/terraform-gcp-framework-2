locals {
  bootstrap_apis = toset([
    "iam.googleapis.com", "iamcredentials.googleapis.com", "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com", "serviceusage.googleapis.com", "storage.googleapis.com",
  ])
  # Only services present in the Callgenie stack; no production IAM or runtime SAs.
  apply_roles = toset([
    "roles/compute.admin", "roles/cloudsql.admin", "roles/secretmanager.admin",
    "roles/storage.admin", "roles/artifactregistry.admin", "roles/datastore.owner",
    "roles/run.admin", "roles/serviceusage.serviceUsageAdmin",
    "roles/servicenetworking.networksAdmin", "roles/iam.serviceAccountUser",
  ])
  plan_roles = toset([
    "roles/viewer", "roles/iam.securityReviewer", "roles/serviceusage.serviceUsageConsumer",
  ])
  apply_subject = "${var.github_subject_prefix}:environment:callgenie"
}

resource "google_project_service" "bootstrap" {
  for_each           = local.bootstrap_apis
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_storage_bucket" "state" {
  project                     = var.project_id
  name                        = var.state_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  versioning { enabled = true }
  depends_on = [google_project_service.bootstrap]
}

resource "google_storage_bucket" "artifacts" {
  project                     = var.project_id
  name                        = var.artifact_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  lifecycle_rule {
    condition { age = 90 }
    action { type = "Delete" }
  }
  depends_on = [google_project_service.bootstrap]
}

resource "google_service_account" "plan" {
  project      = var.project_id
  account_id   = "tf-plan-callgenie"
  display_name = "Callgenie Terraform plan"
  depends_on   = [google_project_service.bootstrap]
}

resource "google_service_account" "apply" {
  project      = var.project_id
  account_id   = "tf-apply-callgenie"
  display_name = "Callgenie Terraform apply"
  depends_on   = [google_project_service.bootstrap]
}

resource "google_project_iam_member" "plan" {
  for_each = local.plan_roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.plan.email}"
}

resource "google_project_iam_member" "apply" {
  for_each = local.apply_roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.apply.email}"
}

# Terraform plans also create/delete a state lock. Scope this access to the
# dedicated dev state bucket, not project-wide storage permissions.
resource "google_storage_bucket_iam_member" "state" {
  for_each = {
    plan  = google_service_account.plan.email
    apply = google_service_account.apply.email
  }
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${each.value}"
}

resource "google_storage_bucket_iam_member" "artifacts" {
  for_each = {
    plan  = google_service_account.plan.email
    apply = google_service_account.apply.email
  }
  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${each.value}"
}

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "callgenie-github"
  display_name              = "Callgenie GitHub Actions"
  depends_on                = [google_project_service.bootstrap]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }
  # PR plan tokens do not contain an environment claim. Apply tokens must
  # name the callgenie GitHub Environment AND originate from main.
  attribute_condition = "assertion.repository == '${var.github_repository}' && assertion.sub.startsWith('${var.github_subject_prefix}:') && (assertion.sub != '${local.apply_subject}' || assertion.ref == 'refs/heads/main')"
  oidc { issuer_uri = "https://token.actions.githubusercontent.com" }
}

resource "google_service_account_iam_member" "plan_federation" {
  service_account_id = google_service_account.plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

resource "google_service_account_iam_member" "apply_federation" {
  service_account_id = google_service_account.apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/subject/${local.apply_subject}"
}
