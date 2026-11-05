data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  state_bucket = "${var.project}-tfstate-${local.account_id}-${var.region}"
}

# ---------- Remote state (S3 with native lockfile locking) ----------
resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "tfstate_tls" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate_tls.json
}

# ---------- GitHub Actions OIDC (no long-lived keys) ----------
# An account can hold only one GitHub OIDC provider, and this account already
# has one (client_id sts.amazonaws.com), so reference it instead of creating it.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# One role per repo/environment. Trust is scoped to the exact repo and the
# GitHub Environment (so prod deploys can require manual approval).
data "aws_iam_policy_document" "github_trust" {
  for_each = {
    for pair in setproduct(["infra", "app"], var.environments) :
    "${pair[0]}-${pair[1]}" => { repo = pair[0] == "infra" ? var.infra_repo : var.app_repo, env = pair[1] }
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.repo_sub_prefixes[each.value.repo]}:environment:${each.value.env}"]
    }
  }
}

resource "aws_iam_role" "github" {
  for_each           = data.aws_iam_policy_document.github_trust
  name               = "${var.project}-gha-${each.key}"
  assume_role_policy = each.value.json
}

# Infra roles get broad rights initially (Terraform creates VPC/ECS/RDS/etc.).
# TODO: replace AdministratorAccess with a scoped permissions boundary once
# the resource set is stable.
resource "aws_iam_role_policy_attachment" "infra_admin" {
  for_each   = { for k, r in aws_iam_role.github : k => r if startswith(k, "infra-") }
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
