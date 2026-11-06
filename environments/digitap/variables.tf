variable "project_id" {
  type    = string
  default = "prj-dg-api-prod-shared"
  validation {
    condition     = var.project_id == "prj-dg-api-prod-shared"
    error_message = "This stack is scoped to prj-dg-api-prod-shared. Update YAML and this guard together to retarget it."
  }
}
variable "region" {
  type    = string
  default = "asia-south1"
}
variable "environment" {
  type    = string
  default = "digitap"
}
