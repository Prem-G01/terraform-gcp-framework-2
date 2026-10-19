variable "vpcs" {
  description = "Managed VPC self-links for optional Direct VPC egress."
  type        = map(string)
  default     = {}
}

variable "subnets" {
  description = "Managed subnet self-links for optional Direct VPC egress."
  type        = map(string)
  default     = {}
}

variable "project_id" {

  type = string

}

variable "config" {

  type = any

}

variable "service_accounts" {

  type = map(string)

}
