output "domain_name" { value = aws_cloudfront_distribution.this.domain_name }
output "url" { value = "https://${aws_cloudfront_distribution.this.domain_name}" }
output "distribution_id" { value = aws_cloudfront_distribution.this.id }
output "distribution_arn" { value = aws_cloudfront_distribution.this.arn }
output "web_bucket_name" { value = aws_s3_bucket.web.id }
output "web_bucket_arn" { value = aws_s3_bucket.web.arn }
output "web_acl_name" { value = aws_wafv2_web_acl.this.name }
