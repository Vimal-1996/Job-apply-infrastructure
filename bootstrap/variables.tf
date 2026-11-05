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

variable "repo_sub_prefixes" {
  description = <<-EOT
    OIDC subject prefix per repo. These GitHub repos use immutable subjects
    (owner/repo numeric IDs), so the token `sub` is
    "repo:<owner>@<ownerId>/<repo>@<repoId>:environment:<env>", not the
    name-only form. Read it with:
    gh api repos/<owner>/<repo>/actions/oidc/customization/sub
  EOT
  type        = map(string)
  default = {
    "Job-apply-infrastructure"         = "repo:Vimal-1996@85448052/Job-apply-infrastructure@1447388634"
    "Job-apply-enterprise-application" = "repo:Vimal-1996@85448052/Job-apply-enterprise-application@1447388512"
  }
}
