variable "project_id" {
  description = "GCP project ID for CallGenie; keep aligned with deployment.yaml."
  type        = string
  default     = "prj-dg-cl-apps-dev"

  validation {
    condition     = var.project_id != "replace-callgenie-project-id"
    error_message = "Set a real CallGenie project ID in deployment.yaml and variables.tf before planning."
  }
}

variable "region" {
  type    = string
  default = "asia-south1"
}

variable "environment" {
  type    = string
  default = "callgenie"
}
