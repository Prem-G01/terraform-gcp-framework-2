variable "hub_project_id" {
  description = "Project that holds the state / artifact / log buckets. All three Terraform state prefixes and every environment's exported logs live here."
  type        = string
}

variable "spoke_project_id" {
  description = "Project whose Cloud Logging is exported to the hub log bucket (where the saafe resources are deployed). A log sink and the logging API are created here."
  type        = string
}

variable "region" {
  type = string
  # A default is a deliberate convenience for a stack a human runs once by
  # hand with -var always available — same reasoning as bootstrap/variables.tf.
  default = "asia-south1" # hardcode-allow: manually-run bootstrap default, overridable via -var
}

variable "state_bucket_name" {
  description = "Globally-unique GCS bucket for Terraform remote state. Each environment uses it under -backend-config=\"prefix=<env>\" (saafe/, dev/, ...)."
  type        = string
}

variable "artifact_bucket_name" {
  description = "Globally-unique GCS bucket for manually-archived plan / apply output. Nothing writes to it automatically in this model."
  type        = string
}

variable "log_bucket_name" {
  description = "Globally-unique GCS bucket that receives the spoke project's exported logs."
  type        = string
}

variable "state_bucket_retention_days" {
  description = "Days a noncurrent state object version is kept before deletion. Versioning itself is always on."
  type        = number
  default     = 90
}

variable "artifact_bucket_retention_days" {
  description = "Age at which an archived artifact object is deleted."
  type        = number
  default     = 180
}

variable "log_bucket_retention_days" {
  description = "Age at which an exported log object is deleted."
  type        = number
  default     = 400
}

variable "log_sink_name" {
  description = "Name of the log sink created in the spoke project."
  type        = string
  default     = "central-log-export"
}

variable "log_filter" {
  description = "Cloud Logging filter for what the spoke project exports. Empty string exports every log entry."
  type        = string
  default     = ""
}
