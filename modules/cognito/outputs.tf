output "user_pool_id" { value = aws_cognito_user_pool.this.id }
output "user_pool_arn" { value = aws_cognito_user_pool.this.arn }
output "web_client_id" { value = aws_cognito_user_pool_client.web.id }
output "issuer" { value = "https://cognito-idp.${split("_", aws_cognito_user_pool.this.id)[0]}.amazonaws.com/${aws_cognito_user_pool.this.id}" }
output "jwks_url" { value = "https://cognito-idp.${split("_", aws_cognito_user_pool.this.id)[0]}.amazonaws.com/${aws_cognito_user_pool.this.id}/.well-known/jwks.json" }
output "hosted_ui_domain" { value = "${aws_cognito_user_pool_domain.this.domain}.auth.${split("_", aws_cognito_user_pool.this.id)[0]}.amazoncognito.com" }
