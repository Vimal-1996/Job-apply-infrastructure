# Production. One stack: unlike dev there is no runtime/persistent split,
# because production is never torn down. Same AWS account as dev; every name
# carries the -prod suffix.
#
# First-time setup:
#   1. terraform apply                      (the API has no image yet, so its tasks wait)
#   2. run the app repo's "Deploy prod" workflow (pushes the image and the web app)
#   3. create the first admin (see docs/production.md)
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
  backend "s3" {
    bucket       = "job-apply-tfstate-418272768931-us-east-1"
    key          = "prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = { Project = "job-apply", Environment = "prod", ManagedBy = "terraform", Stack = "prod" }
  }
}

data "aws_caller_identity" "current" {}

locals {
  name   = "job-apply-prod"
  region = "us-east-1"
  # The pool's sign-in domain follows a fixed pattern (see modules/cognito).
  # Computing it here breaks a cycle: the pool's emails link to the site, and
  # the site's security policy must allow the sign-in domain.
  cognito_domain = "${local.name}-${data.aws_caller_identity.current.account_id}.auth.${local.region}.amazoncognito.com"
}

variable "allow_teardown" {
  description = <<-EOT
    false (default): production is protected from deletion: database and user
    pool deletion protection on, final DB snapshot, non-empty buckets and image
    registry can't be deleted. true: all of that is relaxed so
    `terraform destroy` can remove everything. See docs/production.md.
  EOT
  type        = bool
  default     = false
}

variable "alarm_email" {
  description = "Where production alerts are sent (confirm the subscription email once)."
  type        = string
}

# ---------- Network ----------
module "vpc" {
  source   = "../../modules/vpc"
  name     = local.name
  cidr     = "10.20.0.0/16"
  az_count = 2
  # CloudFront VPC origins aren't supported in this AZ.
  exclude_zone_ids = ["use1-az3"]
}

module "nat" {
  source                 = "../../modules/nat"
  name                   = local.name
  public_subnet_id       = module.vpc.public_subnet_ids[0]
  private_route_table_id = module.vpc.private_route_table_id
}

# ---------- Identity ----------
module "public_assets" {
  source        = "../../modules/public_assets"
  name          = local.name
  force_destroy = var.allow_teardown
}

module "cognito" {
  source = "../../modules/cognito"
  name   = local.name
  # Self sign-up goes through the API (admin-created users always pass the
  # pre-sign-up check); Google sign-in is off, so the allowlist stays empty.
  allowed_emails           = []
  callback_urls            = ["${module.web_edge.url}/callback"]
  logout_urls              = ["${module.web_edge.url}/"]
  app_url                  = module.web_edge.url
  logo_url                 = module.public_assets.logo_url
  deletion_protection      = !var.allow_teardown
  case_sensitive_usernames = false
}

# ---------- Data ----------
module "db" {
  source                    = "../../modules/rds_postgres"
  name                      = local.name
  vpc_id                    = module.vpc.vpc_id
  subnet_ids                = module.vpc.db_subnet_ids
  client_security_group_ids = [module.api.tasks_security_group_id]
  instance_class            = "db.t4g.micro"
  deletion_protection       = !var.allow_teardown
  skip_final_snapshot       = var.allow_teardown
}

# ---------- API ----------
module "ecr" {
  source       = "../../modules/ecr"
  name         = "${local.name}-api"
  force_delete = var.allow_teardown
}

module "api" {
  source             = "../../modules/ecs_api"
  name               = local.name
  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = module.vpc.vpc_cidr
  private_subnet_ids = module.vpc.private_subnet_ids
  repository_url     = module.ecr.repository_url
  db_secret_arn      = module.db.master_secret_arn
  user_pool_arn      = module.cognito.user_pool_arn
  min_tasks          = 2
  max_tasks          = 6
  environment = {
    NODE_ENV             = "production"
    API_BASE_PATH        = "/api"
    TRUST_PROXY_HOPS     = "2" # CloudFront + load balancer
    CORS_ORIGINS         = module.web_edge.url
    COGNITO_USER_POOL_ID = module.cognito.user_pool_id
    COGNITO_CLIENT_ID    = module.cognito.web_client_id
    DB_HOST              = module.db.address
    DB_PORT              = tostring(module.db.port)
    DB_NAME              = module.db.database_name
    DB_POOL_SIZE         = "10"
    # Cognito's default sender allows 50 emails/day until SES (needs a domain).
    SIGNUP_PER_DAY = "30"
  }
}

# ---------- Edge ----------
module "web_edge" {
  source           = "../../modules/web_edge"
  name             = local.name
  region           = local.region
  api_alb_arn      = module.api.alb_arn
  api_alb_dns_name = module.api.alb_dns_name
  cognito_domain   = local.cognito_domain
  force_destroy    = var.allow_teardown
}

# ---------- Alerts ----------
module "alarms" {
  source                  = "../../modules/alarms"
  name                    = local.name
  email                   = var.alarm_email
  alb_arn_suffix          = module.api.alb_arn_suffix
  target_group_arn_suffix = module.api.target_group_arn_suffix
  cluster_name            = module.api.cluster_name
  service_name            = module.api.service_name
  db_instance_id          = module.db.instance_id
  distribution_id         = module.web_edge.distribution_id
}

# ---------- What the app repo's deploy workflow needs ----------
# Build settings for the web app, read at deploy time (nothing hard-coded).
resource "aws_ssm_parameter" "deploy" {
  for_each = {
    "web/cognito-authority" = module.cognito.issuer
    "web/cognito-client-id" = module.cognito.web_client_id
    "web/cognito-domain"    = "https://${module.cognito.hosted_ui_domain}"
    "web/api-url"           = "/api" # same origin: CloudFront forwards /api/* to the API
    "web/bucket"            = module.web_edge.web_bucket_name
    "web/distribution-id"   = module.web_edge.distribution_id
    "web/url"               = module.web_edge.url
    "api/repository-url"    = module.ecr.repository_url
    "api/cluster"           = module.api.cluster_name
    "api/service"           = module.api.service_name
    "api/task-family"       = module.api.task_family
    "api/container"         = module.api.container_name
  }
  name           = "/${local.name}/deploy/${each.key}"
  type           = "String"
  insecure_value = each.value
}

# The app repo's prod role (created by bootstrap, trusted only from its
# GitHub "prod" environment) may deploy this stack's API and web app, and
# nothing else.
data "aws_iam_role" "app_deploy" {
  name = "job-apply-gha-app-prod"
}

resource "aws_iam_role_policy" "app_deploy" {
  name = "deploy-prod"
  role = data.aws_iam_role.app_deploy.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "EcrLogin", Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      {
        Sid    = "EcrPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages",
        ]
        Resource = module.ecr.repository_arn
      },
      {
        Sid      = "ReadDeploySettings"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:${local.region}:*:parameter/${local.name}/*"
      },
      { Sid = "RecordImageTag", Effect = "Allow", Action = ["ssm:PutParameter"], Resource = module.api.image_tag_parameter_arn },
      {
        Sid      = "EcsTaskDefinitions"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
        Resource = "*" # these actions don't support resource scoping
      },
      {
        Sid      = "EcsDeploy"
        Effect   = "Allow"
        Action   = ["ecs:UpdateService", "ecs:DescribeServices"]
        Resource = "arn:aws:ecs:${local.region}:*:service/${module.api.cluster_name}/${module.api.service_name}"
      },
      {
        Sid       = "PassTaskRoles"
        Effect    = "Allow"
        Action    = ["iam:PassRole"]
        Resource  = [module.api.execution_role_arn, module.api.task_role_arn]
        Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
      },
      {
        Sid      = "WebUpload"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:PutObject", "s3:DeleteObject", "s3:GetObject"]
        Resource = [module.web_edge.web_bucket_arn, "${module.web_edge.web_bucket_arn}/*"]
      },
      {
        Sid      = "CacheInvalidation"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
        Resource = module.web_edge.distribution_arn
      },
    ]
  })
}

# ---------- Outputs ----------
output "url" { value = module.web_edge.url }
output "cognito_user_pool_id" { value = module.cognito.user_pool_id }
output "cognito_web_client_id" { value = module.cognito.web_client_id }
output "cognito_domain" { value = module.cognito.hosted_ui_domain }

# Guard: the computed domain must match what the module actually creates.
check "cognito_domain_matches" {
  assert {
    condition     = module.cognito.hosted_ui_domain == local.cognito_domain
    error_message = "modules/cognito changed its domain pattern; update local.cognito_domain."
  }
}
output "ecr_repository_url" { value = module.ecr.repository_url }
output "db_address" { value = module.db.address }
output "api_log_group" { value = module.api.log_group_name }
output "alerts_topic_arn" { value = module.alarms.topic_arn }
