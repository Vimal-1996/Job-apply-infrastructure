variable "name" {
  description = "Name prefix including the environment, e.g. job-apply-prod."
  type        = string
}

variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }

variable "private_subnet_ids" {
  description = "For the load balancer and tasks. Must avoid AZ use1-az3 (no CloudFront VPC origins there)."
  type        = list(string)
}

variable "repository_url" { type = string }

variable "base_path" {
  description = "Path prefix the API serves under (CloudFront forwards /api/*)."
  type        = string
  default     = "/api"
}

variable "environment" {
  description = "Non-secret environment variables for the container."
  type        = map(string)
}

variable "db_secret_arn" {
  description = "RDS-managed secret holding the database username and password."
  type        = string
}

variable "extra_secrets" {
  description = "More secrets for the container: environment variable name => Secrets Manager secret ARN (the whole secret string becomes the value)."
  type        = map(string)
  default     = {}
}

variable "user_pool_arn" { type = string }

variable "extra_task_policy_statements" {
  description = "More IAM statements for the API's task role (e.g. access to a user-files bucket)."
  type        = any
  default     = []
}

variable "cpu" {
  type    = number
  default = 256
}

variable "memory" {
  type    = number
  default = 512
}

variable "min_tasks" {
  description = "At least 2 spreads tasks over 2 AZs and allows zero-downtime deploys."
  type        = number
  default     = 2
}

variable "max_tasks" {
  type    = number
  default = 6
}

variable "log_retention_days" {
  type    = number
  default = 30
}
