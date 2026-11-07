variable "name" {
  description = "Name prefix including the environment, e.g. job-apply-prod."
  type        = string
}

variable "region" {
  description = "Region of the Cognito user pool (for the content security policy)."
  type        = string
}

variable "api_alb_arn" { type = string }
variable "api_alb_dns_name" { type = string }

variable "cognito_domain" {
  description = "The user pool's sign-in domain, e.g. job-apply-prod-123.auth.us-east-1.amazoncognito.com."
  type        = string
}

variable "rate_limit_per_5min" {
  description = "Requests per IP per 5 minutes before the WAF blocks (all paths)."
  type        = number
  default     = 2000
}
