terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0" }
  }
}

# Email alerts for the things that mean users are affected or soon will be.
# The subscription must be confirmed once from the email AWS sends.

variable "name" { type = string }
variable "email" { type = string }
variable "alb_arn_suffix" { type = string }
variable "target_group_arn_suffix" { type = string }
variable "cluster_name" { type = string }
variable "service_name" { type = string }
variable "db_instance_id" { type = string }
variable "distribution_id" { type = string }

# CloudWatch alarms can't publish to a topic encrypted with the AWS-managed
# SNS key, and alert texts aren't sensitive.
#trivy:ignore:AWS-0095
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.email
}

locals {
  alarms = {
    api-5xx = {
      description = "The API returned server errors"
      namespace   = "AWS/ApplicationELB"
      metric      = "HTTPCode_Target_5XX_Count"
      stat        = "Sum"
      threshold   = 10
      comparison  = "GreaterThanThreshold"
      periods     = 1
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
    }
    api-unhealthy-targets = {
      description = "API containers are failing health checks"
      namespace   = "AWS/ApplicationELB"
      metric      = "UnHealthyHostCount"
      stat        = "Maximum"
      threshold   = 0
      comparison  = "GreaterThanThreshold"
      periods     = 2
      dimensions  = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
    }
    api-slow = {
      description = "API p95 response time above 2s"
      namespace   = "AWS/ApplicationELB"
      metric      = "TargetResponseTime"
      stat        = "p95"
      threshold   = 2
      comparison  = "GreaterThanThreshold"
      periods     = 3
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
    }
    api-cpu = {
      description = "API CPU high (autoscaling may be at its maximum)"
      namespace   = "AWS/ECS"
      metric      = "CPUUtilization"
      stat        = "Average"
      threshold   = 85
      comparison  = "GreaterThanThreshold"
      periods     = 3
      dimensions  = { ClusterName = var.cluster_name, ServiceName = var.service_name }
    }
    db-cpu = {
      description = "Database CPU high"
      namespace   = "AWS/RDS"
      metric      = "CPUUtilization"
      stat        = "Average"
      threshold   = 80
      comparison  = "GreaterThanThreshold"
      periods     = 3
      dimensions  = { DBInstanceIdentifier = var.db_instance_id }
    }
    db-storage = {
      description = "Database free storage below 2 GB"
      namespace   = "AWS/RDS"
      metric      = "FreeStorageSpace"
      stat        = "Minimum"
      threshold   = 2147483648
      comparison  = "LessThanThreshold"
      periods     = 1
      dimensions  = { DBInstanceIdentifier = var.db_instance_id }
    }
    db-connections = {
      description = "Database connections near the small instance's limit"
      namespace   = "AWS/RDS"
      metric      = "DatabaseConnections"
      stat        = "Maximum"
      threshold   = 70
      comparison  = "GreaterThanThreshold"
      periods     = 2
      dimensions  = { DBInstanceIdentifier = var.db_instance_id }
    }
    edge-5xx-rate = {
      description = "More than 5% of requests to the site failed"
      namespace   = "AWS/CloudFront"
      metric      = "5xxErrorRate"
      stat        = "Average"
      threshold   = 5
      comparison  = "GreaterThanThreshold"
      periods     = 2
      dimensions  = { DistributionId = var.distribution_id, Region = "Global" }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each            = local.alarms
  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = contains(["Sum", "Average", "Minimum", "Maximum", "SampleCount"], each.value.stat) ? each.value.stat : null
  extended_statistic  = contains(["Sum", "Average", "Minimum", "Maximum", "SampleCount"], each.value.stat) ? null : each.value.stat
  period              = 300
  evaluation_periods  = each.value.periods
  threshold           = each.value.threshold
  comparison_operator = each.value.comparison
  dimensions          = each.value.dimensions
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

output "topic_arn" { value = aws_sns_topic.alerts.arn }
