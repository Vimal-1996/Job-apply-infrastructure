output "state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "github_role_arns" {
  value = { for k, r in aws_iam_role.github : k => r.arn }
}
