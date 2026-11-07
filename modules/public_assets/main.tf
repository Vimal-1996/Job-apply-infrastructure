terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0" }
  }
}

# Public, cacheable static files that must be reachable from outside the app,
# e.g. the logo in emails Cognito sends (email clients can't show SVG or
# inline images, so it is a hosted PNG). The bucket stays private; only
# CloudFront can read it (origin access control).

data "aws_caller_identity" "current" {}

locals {
  logo_file = "${path.module}/assets/logo-email.png"
  # Content hash in the key: a new logo gets a new URL, so email clients and
  # caches never show a stale one.
  logo_key = "brand/logo-${substr(filemd5(local.logo_file), 0, 10)}.png"
}

resource "aws_s3_bucket" "this" {
  bucket = "${var.name}-public-assets-${data.aws_caller_identity.current.account_id}"
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

# Public brand assets: AWS-managed encryption is enough.
#trivy:ignore:AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "this" {
  name                              = "${var.name}-public-assets"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

# Serves a single public image (the email logo); a WAF adds cost without protecting anything.
#trivy:ignore:AWS-0011
resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  comment         = "${var.name} public assets (email images)"
  price_class     = "PriceClass_100"
  is_ipv6_enabled = true

  origin {
    origin_id                = "s3"
    domain_name              = aws_s3_bucket.this.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  default_cache_behavior {
    target_origin_id       = "s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "CloudFrontReadOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket     = aws_s3_bucket.this.id
  policy     = data.aws_iam_policy_document.bucket.json
  depends_on = [aws_s3_bucket_public_access_block.this]
}

resource "aws_s3_object" "logo" {
  bucket        = aws_s3_bucket.this.id
  key           = local.logo_key
  source        = local.logo_file
  etag          = filemd5(local.logo_file)
  content_type  = "image/png"
  cache_control = "public, max-age=31536000, immutable"
}
