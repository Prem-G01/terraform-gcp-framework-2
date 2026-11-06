variable "project_id" {
  type = string
}
variable "config" {
  type = any
}
variable "service_accounts" {
  type    = map(string)
  default = {}
}
variable "vpcs" {
  type    = map(string)
  default = {}
}
variable "subnets" {
  type    = map(string)
  default = {}
}
