locals {
  bootstrap_apis = toset([
    "iam.googleapis.com", "iamcredentials.googleapis.com", "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com", "serviceusage.googleapis.com", "storage.googleapis.com",
    "logging.googleapis.com",
  ])
  # Callgenie dev service permissions; the VM runtime identity emits telemetry only.
  apply_roles = toset([
    "roles/compute.admin", "roles/cloudsql.admin", "roles/secretmanager.admin",
    "roles/storage.admin", "roles/artifactregistry.admin", "roles/datastore.owner",
    "roles/run.admin", "roles/serviceusage.serviceUsageAdmin", "roles/monitoring.admin",
    "roles/servicenetworking.networksAdmin", "roles/iam.serviceAccountUser",
  ])
  plan_roles = toset([
    "roles/viewer", "roles/iam.securityReviewer", "roles/serviceusage.serviceUsageConsumer",
    "roles/logging.privateLogViewer",
  ])
  state_prefix    = "${var.history_prefix}/callgenie"
  artifact_prefix = "${var.history_prefix}/deployments/callgenie"
  logging_prefix  = "${var.history_prefix}/cloud-logging"
  apply_subject   = "${var.github_subject_prefix}:environment:callgenie"
}

resource "google_project_service" "bootstrap" {
  for_each           = local.bootstrap_apis
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
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

resource "google_logging_project_sink" "central_history" {
  project                = var.project_id
  name                   = "callgenie-central-history"
  destination            = "storage.googleapis.com/${google_storage_bucket.shared_history.name}"
  filter                 = ""
  unique_writer_identity = true
  depends_on             = [google_project_service.bootstrap]
}

# Shared history storage is created once; future environments reuse this bucket.
resource "google_storage_bucket" "shared_history" {
  project                     = var.storage_project_id
  name                        = var.central_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  versioning { enabled = true }
  soft_delete_policy { retention_duration_seconds = 604800 }
  labels = {
    application = "infrastructure"
    purpose     = "terraform-history"
    managed_by  = "terraform"
  }
  lifecycle { prevent_destroy = true }
}

resource "google_storage_bucket_iam_member" "shared_state" {
  for_each = {
    plan  = google_service_account.plan.email
    apply = google_service_account.apply.email
  }
  bucket = google_storage_bucket.shared_history.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${each.value}"
  condition {
    title      = "callgenie-state-and-checkpoint-only"
    expression = "resource.name == 'projects/_/buckets/${var.central_bucket_name}' || resource.name.startsWith('projects/_/buckets/${var.central_bucket_name}/objects/${local.state_prefix}/')"
  }
}

resource "google_storage_bucket_iam_member" "shared_artifacts" {
  for_each = {
    plan  = google_service_account.plan.email
    apply = google_service_account.apply.email
  }
  bucket = google_storage_bucket.shared_history.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${each.value}"
  condition {
    title      = "callgenie-deployment-history-only"
    expression = "resource.name.startsWith('projects/_/buckets/${var.central_bucket_name}/objects/${local.artifact_prefix}/')"
  }
}

resource "google_storage_bucket_iam_member" "shared_logging" {
  bucket = google_storage_bucket.shared_history.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.plan.email}"
  condition {
    title      = "callgenie-cloud-logging-archives-only"
    expression = "resource.name.startsWith('projects/_/buckets/${var.central_bucket_name}/objects/${local.logging_prefix}/')"
  }
}

resource "google_storage_bucket_iam_member" "shared_log_export_writer" {
  bucket = google_storage_bucket.shared_history.name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.central_history.writer_identity
}


# A shared VM identity that can emit telemetry, without application/data access.
resource "google_service_account" "vm_monitoring" {
  project      = var.project_id
  account_id   = var.monitoring_service_account_id
  display_name = "Callgenie VM monitoring"
  description  = "Emits VM and Redis monitoring metrics and system logs."
  depends_on   = [google_project_service.bootstrap]
}
resource "google_project_iam_member" "vm_monitoring" {
  for_each = toset(["roles/monitoring.metricWriter", "roles/logging.logWriter"])
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.vm_monitoring.email}"
}
