terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0" }
  }
}

# The API on ECS Fargate behind an *internal* Application Load Balancer.
# Nothing here is reachable from the internet: CloudFront reaches the load
# balancer through a VPC origin, and the security group admits only
# CloudFront's origin-facing addresses.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

locals {
  container   = "api"
  port        = 3000
  health_path = "${var.base_path}/health"
  image       = "${var.repository_url}:${aws_ssm_parameter.image_tag.insecure_value}"
}

# ---------- Image tag: written by the deploy workflow, read here ----------
# The deploy workflow pushes an image and sets this; Terraform then uses the
# same tag, so infrastructure changes roll out with the deployed image.
resource "aws_ssm_parameter" "image_tag" {
  name           = "/${var.name}/api/image-tag"
  type           = "String"
  insecure_value = "bootstrap" # until the first deploy pushes an image
  lifecycle {
    ignore_changes = [insecure_value]
  }
}

# ---------- Security groups ----------
resource "aws_security_group" "alb" {
  name        = "${var.name}-api-alb"
  description = "Internal API load balancer: CloudFront only"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "CloudFront VPC origin"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = local.port
  to_port                      = local.port
}

resource "aws_security_group" "tasks" {
  name        = "${var.name}-api-tasks"
  description = "API tasks: load balancer in; HTTPS (Cognito, AWS APIs) and DB out"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.port
  to_port                      = local.port
}

# Cognito has no VPC endpoint, so tasks reach it (and other AWS APIs) on 443 via the NAT.
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "tasks_https" {
  security_group_id = aws_security_group.tasks.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Cognito, ECR, CloudWatch, Secrets Manager (via NAT)"
}

resource "aws_vpc_security_group_egress_rule" "tasks_db" {
  security_group_id = aws_security_group.tasks.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  description       = "PostgreSQL"
}

# ---------- Load balancer ----------
resource "aws_lb" "this" {
  name                       = "${var.name}-api"
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = var.private_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  idle_timeout               = 60
}

resource "aws_lb_target_group" "api" {
  name                 = "${var.name}-api"
  port                 = local.port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = local.health_path
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# Internal load balancer with no public address; only CloudFront's
# VPC origin reaches it, over the AWS network. HTTPS needs a certificate for a
# domain we don't have yet; revisit when one is added.
#trivy:ignore:AWS-0054
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP" # private: CloudFront terminates HTTPS and reaches this over the AWS network
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# ---------- IAM ----------
data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# Used by ECS itself: pull the image, write logs, read the DB secret.
resource "aws_iam_role" "execution" {
  name               = "${var.name}-api-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  name = "db-secret"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [var.db_secret_arn] }]
  })
}

# Used by the API code: manage users in this environment's pool only.
resource "aws_iam_role" "task" {
  name               = "${var.name}-api-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy" "task_cognito" {
  name = "cognito-users"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cognito-idp:AdminGetUser",
        "cognito-idp:AdminListGroupsForUser",
        "cognito-idp:AdminCreateUser",
        "cognito-idp:AdminAddUserToGroup",
        "cognito-idp:AdminRemoveUserFromGroup",
        "cognito-idp:AdminDeleteUser",
        "cognito-idp:AdminUserGlobalSignOut",
        "cognito-idp:ListUsers",
        "cognito-idp:ListUsersInGroup",
      ]
      Resource = [var.user_pool_arn]
    }]
  })
}

resource "aws_iam_role_policy" "task_extra" {
  count  = length(var.extra_task_policy_statements) > 0 ? 1 : 0
  name   = "extra"
  role   = aws_iam_role.task.id
  policy = jsonencode({ Version = "2012-10-17", Statement = var.extra_task_policy_statements })
}

# ---------- Task definition and service ----------
resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.name}-api"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "this" {
  name = var.name
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name                   = local.container
    image                  = local.image
    essential              = true
    readonlyRootFilesystem = true
    stopTimeout            = 30
    portMappings           = [{ containerPort = local.port, protocol = "tcp" }]
    environment            = [for k, v in var.environment : { name = k, value = v }]
    secrets = [
      { name = "DB_USER", valueFrom = "${var.db_secret_arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${var.db_secret_arn}:password::" },
    ]
    healthCheck = {
      command     = ["CMD-SHELL", "wget -qO- http://127.0.0.1:${local.port}${local.health_path} >/dev/null || exit 1"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.api.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = local.container
      }
    }
  }])
}

# Newest revision of the family: the deploy workflow registers revisions too.
data "aws_ecs_task_definition" "latest" {
  task_definition = aws_ecs_task_definition.api.family
  depends_on      = [aws_ecs_task_definition.api]
}

resource "aws_ecs_service" "api" {
  name    = "api"
  cluster = aws_ecs_cluster.this.id
  # Whichever is newer: Terraform's revision (a config change) or the deploy
  # workflow's (a new image). So Terraform never rolls a deploy back, even
  # mid-deploy before the new image tag is recorded.
  task_definition                    = aws_ecs_task_definition.api.revision >= data.aws_ecs_task_definition.latest.revision ? aws_ecs_task_definition.api.arn : data.aws_ecs_task_definition.latest.arn
  desired_count                      = var.min_tasks
  launch_type                        = "FARGATE"
  platform_version                   = "LATEST"
  health_check_grace_period_seconds  = 60
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  propagate_tags                     = "SERVICE"
  enable_execute_command             = false

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = local.container
    container_port   = local.port
  }

  # A deploy that never gets healthy is rolled back automatically.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    # Autoscaling owns the count. Config changes still roll out: Terraform
    # builds its revision with the deployed image (from the image-tag
    # parameter), and a new revision is the newest one.
    ignore_changes = [desired_count]
  }

  depends_on = [aws_lb_listener.http]
}

# ---------- Autoscaling ----------
resource "aws_appautoscaling_target" "api" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_tasks
  max_capacity       = var.max_tasks
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-api-cpu"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  policy_type        = "TargetTrackingScaling"
  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
