# =============================================================================
# Minimal bootstrap — the whole hub in this model is three GCS buckets plus
# one cross-project log export. No deploy service account, no Workload
# Identity Federation, no per-environment IAM: `terraform` is run locally
# by a human against their own credentials. See docs/deploy-saafe.md.
#
# The full per-environment / WIF / pipeline design still exists unused in
# ../ (bootstrap/main.tf) and ../grants/ if it is ever wanted.
# =============================================================================

locals {
  hub_apis = [
    "storage.googleapis.com",
    "serviceusage.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]
}

resource "google_project_service" "hub" {
  for_each = toset(local.hub_apis)

  project            = var.hub_project_id
  service            = each.value
  disable_on_destroy = false
}

# --- State bucket ---------------------------------------------------------
# One bucket, one object prefix per environment (saafe/, dev/, prod/, ...),
# selected at `terraform init` time with -backend-config="prefix=<env>".

resource "google_storage_bucket" "state" {
  project  = var.hub_project_id
  name     = var.state_bucket_name
  location = var.region

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

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

  depends_on = [google_project_service.hub]
}

# --- Artifact bucket ----------------------------------------------------
# For manually archiving `terraform show -json` plans / apply outputs.
# Nothing writes here automatically in this model.

resource "google_storage_bucket" "artifacts" {
  project  = var.hub_project_id
  name     = var.artifact_bucket_name
  location = var.region

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  lifecycle_rule {
    condition {
      age = var.artifact_bucket_retention_days
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.hub]
}

# --- Log bucket + cross-project export ---------------------------------
# Every log entry in the spoke project is exported here, so logs outlive
# the spoke project's own lifecycle and sit in the hub project.

resource "google_storage_bucket" "logs" {
  project  = var.hub_project_id
  name     = var.log_bucket_name
  location = var.region

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  lifecycle_rule {
    condition {
      age = var.log_bucket_retention_days
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.hub]
}

resource "google_project_service" "spoke_logging" {
  provider = google.spoke

  project            = var.spoke_project_id
  service            = "logging.googleapis.com"
  disable_on_destroy = false
}

resource "google_logging_project_sink" "spoke_export" {
  provider = google.spoke

  project                = var.spoke_project_id
  name                   = var.log_sink_name
  destination            = "storage.googleapis.com/${google_storage_bucket.logs.name}"
  filter                 = var.log_filter
  unique_writer_identity = true

  depends_on = [google_project_service.spoke_logging]
}

# The sink writes as a Google-managed identity that only exists after the
# sink is created — grant it write access to the log bucket here.
resource "google_storage_bucket_iam_member" "spoke_sink_writes_logs" {
  bucket = google_storage_bucket.logs.name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.spoke_export.writer_identity
}
