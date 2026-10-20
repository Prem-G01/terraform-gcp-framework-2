variable "project_id" { type = string }
variable "region" { type = string }
variable "github_repository" { type = string }

variable "github_subject_prefix" {
  description = "The actual sub_claim_prefix from GitHub's repository OIDC settings, including immutable IDs where enabled."
  type        = string
}

variable "storage_project_id" {
  description = "Central DevOps project hosting the single state/history/log bucket."
  type        = string
}


variable "central_bucket_name" {
  description = "Single shared infrastructure history bucket, created once in the DevOps project."
  type        = string
}
variable "history_prefix" {
  description = "Unique top-level folder for this environment's state, records, and log snapshots."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_-]*$", var.history_prefix))
    error_message = "Use one nonempty lowercase folder name without slashes."
  }
}

variable "monitoring_service_account_id" { type = string }
