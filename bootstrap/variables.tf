variable "project_id" {
  description = "Project that will host the state bucket, artifact bucket, and CI/CD service accounts. Can be a dedicated ops/platform project or the same project the platform deploys into."
  type        = string
}

variable "region" {
  type = string
  # A default here (unlike in modules/) is a deliberate convenience for a
  # stack a human runs once, by hand, with -var flags always available to
  # override it — see docs/state-management.md "Bootstrapping".
  default = "asia-south1" # hardcode-allow: manually-run bootstrap default, always overridable via -var
}

variable "state_bucket_name" {
  description = "Globally-unique GCS bucket name for Terraform remote state. No default — bucket names collide platform-wide, so this must be chosen deliberately per org, not inherited from a template value."
  type        = string
}

variable "artifact_bucket_name" {
  description = "Globally-unique GCS bucket name for validation.json / plan.json / plan.txt / metadata.json produced by CI/CD (see docs/logging.md)."
  type        = string
}

variable "state_bucket_retention_days" {
  description = "How long a noncurrent state object version is kept before GCS deletes it. Object versioning itself is always on (see main.tf) — this only bounds how far back you can roll back."
  type        = number
  default     = 90
}

variable "environments" {
  description = "Environment names this bootstrap creates a dedicated tf-plan-<env>/tf-apply-<env> pair for (used for per-environment IAM conditions, not for creating environment resources — bootstrap never touches environments/)."
  type        = list(string)
  default     = ["dev", "sit", "uat", "prod", "saafe"]
}

variable "home_environment" {
  description = "The one entry in var.environments whose real GCP project IS var.project_id — its tf-plan/tf-apply pair gets project-level roles granted directly by this stack. Every other environment's pair gets its roles from bootstrap/grants/ instead, applied against that environment's own project."
  type        = string
  default     = "dev"
}

variable "log_bucket_name" {
  description = "Globally-unique GCS bucket name for centralized Cloud Logging export — every environment's logs, kept here rather than in each spoke project. No default, same reasoning as state_bucket_name."
  type        = string
}

variable "log_bucket_retention_days" {
  description = "How long an exported log object is kept before GCS deletes it."
  type        = number
  default     = 400
}

variable "log_sink_writer_identities" {
  description = "Map of environment name to the writer_identity output of that environment's google_logging_project_sink, created in bootstrap/grants/<that project>/ (see docs/logging.md \"Centralized logging\"). Grants each identity write access to the central log bucket. var.home_environment's own sink is wired up directly in main.tf and does not need an entry here."
  type        = map(string)
  default     = {}
}

variable "enable_workload_identity_federation" {
  description = "Create a Workload Identity Federation pool so CI/CD authenticates without a long-lived service-account key (see docs/service-accounts.md). Requires github_repository when true."
  type        = bool
  default     = false
}

variable "github_repository" {
  description = "\"<org>/<repo>\" allowed to assume the CI/CD service accounts via WIF. Required only when enable_workload_identity_federation is true."
  type        = string
  default     = ""
}
