terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0" }
  }
}

# Private files that belong to users (resumes), stored at users/{userId}/...
# Nothing is public: the API signs short-lived upload/download links for the
# file's owner. The browser uploads straight to the bucket, so CORS admits only
# the app's own address.
#
# Uploads arrive tagged status=pending; the API re-tags them status=ready once
# it has verified the file. Anything still pending after a day was abandoned
# and is deleted.

variable "name" {
  description = "Name prefix including the environment, e.g. job-apply-dev."
  type        = string
}

variable "allowed_origins" {
  description = "Web app addresses allowed to upload from the browser, e.g. https://xxxx.cloudfront.net."
  type        = list(string)
}

variable "force_destroy" {
  description = "Allow deleting the bucket with its files (intentional teardown only)."
  type        = bool
  default     = false
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "this" {
  bucket        = "${var.name}-user-files-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Personal data: KMS encryption (AWS-managed key), with bucket keys to keep
# KMS request costs negligible.
#trivy:ignore:AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# No versioning on purpose: when a user deletes a resume it must really be gone.
#trivy:ignore:AWS-0090
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    id     = "expire-abandoned-uploads"
    status = "Enabled"
    filter {
      tag {
        key   = "status"
        value = "pending"
      }
    }
    expiration {
      days = 1
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  cors_rule {
    allowed_methods = ["POST"]
    allowed_origins = var.allowed_origins
    allowed_headers = ["*"]
    max_age_seconds = 3000
  }
}

data "aws_iam_policy_document" "tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
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

resource "aws_s3_bucket_policy" "this" {
  bucket     = aws_s3_bucket.this.id
  policy     = data.aws_iam_policy_document.tls_only.json
  depends_on = [aws_s3_bucket_public_access_block.this]
}

output "bucket_name" { value = aws_s3_bucket.this.id }
output "bucket_arn" { value = aws_s3_bucket.this.arn }
# The address the browser uploads to (for the content security policy).
output "upload_origin" { value = "https://${aws_s3_bucket.this.bucket_regional_domain_name}" }

# What the API needs: sign uploads (which tag objects), verify, re-tag, download, delete.
output "api_policy_statements" {
  value = [
    {
      Sid      = "UserFiles"
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:PutObjectTagging", "s3:GetObject", "s3:DeleteObject"]
      Resource = ["${aws_s3_bucket.this.arn}/users/*"]
    },
    {
      Sid       = "UserFilesList"
      Effect    = "Allow"
      Action    = ["s3:ListBucket"]
      Resource  = [aws_s3_bucket.this.arn]
      Condition = { StringLike = { "s3:prefix" = ["users/*"] } }
    },
  ]
}
