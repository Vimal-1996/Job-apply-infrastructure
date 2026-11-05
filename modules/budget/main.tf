variable "name" { type = string }
variable "email" { type = string }
variable "thresholds_usd" {
  type    = list(number)
  default = [20, 50, 100]
}

# One monthly cost budget per threshold; emails on ACTUAL spend crossing it.
resource "aws_budgets_budget" "monthly" {
  for_each     = toset([for t in var.thresholds_usd : tostring(t)])
  name         = "${var.name}-monthly-${each.key}usd"
  budget_type  = "COST"
  limit_amount = each.key
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.email]
  }
}
