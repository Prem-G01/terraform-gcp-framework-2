variable "project_id" { type = string }
variable "region" { type = string }
variable "github_repository" { type = string }
variable "state_bucket_name" { type = string }
variable "artifact_bucket_name" { type = string }

variable "github_subject_prefix" {
  description = "The actual sub_claim_prefix from GitHub's repository OIDC settings, including immutable IDs where enabled."
  type        = string
}
