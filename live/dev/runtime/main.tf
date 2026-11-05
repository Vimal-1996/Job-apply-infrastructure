# Runtime stack: everything that bills while it exists. `terraform destroy`
# here when you stop developing; `apply` to bring it back. Persistent
# resources (VPC, Cognito, ECR, ...) are untouched.
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket       = "job-apply-tfstate-418272768931-us-east-1"
    key          = "dev/runtime/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = { Project = "job-apply", Environment = "dev", ManagedBy = "terraform", Stack = "dev-runtime" }
  }
}

data "terraform_remote_state" "persistent" {
  backend = "s3"
  config = {
    bucket = "job-apply-tfstate-418272768931-us-east-1"
    key    = "dev/persistent/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  p = data.terraform_remote_state.persistent.outputs
}

module "nat" {
  source                 = "../../../modules/nat"
  name                   = "job-apply-dev"
  public_subnet_id       = local.p.public_subnet_ids[0]
  private_route_table_id = local.p.private_route_table_id
}

# Added in later phases: ALB, ECS service (Fargate Spot), Aurora Serverless v2
# (min 0 ACU, snapshot on destroy / restore on create).
