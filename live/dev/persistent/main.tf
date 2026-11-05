terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    bucket       = "job-apply-tfstate-418272768931-us-east-1"
    key          = "dev/persistent/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = { Project = "job-apply", Environment = "dev", ManagedBy = "terraform", Stack = "dev-persistent" }
  }
}

variable "budget_email" {
  description = "Where AWS budget alerts are sent."
  type        = string
}

variable "allowed_emails" {
  description = "Emails allowed to have an account (single-user app)."
  type        = list(string)
}

variable "google_client_id" {
  type    = string
  default = ""
}

variable "google_client_secret" {
  type      = string
  default   = ""
  sensitive = true
}

module "vpc" {
  source   = "../../../modules/vpc"
  name     = "job-apply-dev"
  cidr     = "10.10.0.0/16"
  az_count = 2
}

# Account-wide budget (one account hosts all environments).
module "budget" {
  source = "../../../modules/budget"
  name   = "job-apply"
  email  = var.budget_email
}

module "cognito" {
  source               = "../../../modules/cognito"
  name                 = "job-apply-dev"
  allowed_emails       = var.allowed_emails
  google_client_id     = var.google_client_id
  google_client_secret = var.google_client_secret
}

output "cognito_user_pool_id" { value = module.cognito.user_pool_id }
output "cognito_web_client_id" { value = module.cognito.web_client_id }
output "cognito_issuer" { value = module.cognito.issuer }
output "cognito_jwks_url" { value = module.cognito.jwks_url }
output "cognito_hosted_ui_domain" { value = module.cognito.hosted_ui_domain }

output "vpc_id" { value = module.vpc.vpc_id }
output "public_subnet_ids" { value = module.vpc.public_subnet_ids }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }
output "db_subnet_ids" { value = module.vpc.db_subnet_ids }
output "private_route_table_id" { value = module.vpc.private_route_table_id }
