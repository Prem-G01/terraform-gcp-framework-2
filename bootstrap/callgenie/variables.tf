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
variable "history_bucket_name" {
  description = "Single central bucket for state, deployment records, and Cloud Logging export."
  type        = string
}
