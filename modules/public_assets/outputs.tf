output "base_url" { value = "https://${aws_cloudfront_distribution.this.domain_name}" }
output "logo_url" { value = "https://${aws_cloudfront_distribution.this.domain_name}/${aws_s3_object.logo.key}" }
output "bucket_name" { value = aws_s3_bucket.this.id }
