variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name used as a resource prefix."
  type        = string
  default     = "job-apply"
}

variable "github_org" {
  description = "GitHub user or org that owns the repositories."
  type        = string
}

variable "infra_repo" {
  type    = string
  default = "Job-apply-infrastructure"
}

variable "app_repo" {
  type    = string
  default = "Job-apply-enterprise-application"
}

variable "environments" {
  description = "Environments sharing this single AWS account (resources get an env suffix)."
  type        = list(string)
  default     = ["dev", "staging", "prod"]
}
