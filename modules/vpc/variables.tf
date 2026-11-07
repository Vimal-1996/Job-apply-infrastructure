variable "name" {
  description = "Name prefix including the environment suffix, e.g. job-apply-dev."
  type        = string
}

variable "cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of AZs. Aurora needs >= 2 for its subnet group, so keep 2+ even in dev."
  type        = number
  default     = 2
}

variable "exclude_zone_ids" {
  description = "AZ ids to avoid, e.g. use1-az3 (CloudFront VPC origins don't support it)."
  type        = list(string)
  default     = []
}
