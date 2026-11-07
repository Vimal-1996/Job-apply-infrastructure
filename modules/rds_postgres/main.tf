terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0" }
  }
}

# A single PostgreSQL instance in the VPC's database subnets. Only the
# security groups passed in `client_security_group_ids` can connect, and only
# over TLS. The master password is generated and kept by RDS in Secrets Manager.

variable "name" {
  description = "Name prefix including the environment, e.g. job-apply-prod."
  type        = string
}

variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }

variable "client_security_group_ids" {
  description = "Security groups allowed to connect (the API's tasks)."
  type        = list(string)
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "engine_version" {
  description = "Major version; minor versions are upgraded automatically in the maintenance window."
  type        = string
  default     = "16"
}

variable "allocated_storage_gb" {
  type    = number
  default = 20
}

variable "max_allocated_storage_gb" {
  description = "Storage autoscaling ceiling."
  type        = number
  default     = 100
}

variable "database_name" {
  type    = string
  default = "jobapply"
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "deletion_protection" {
  type    = bool
  default = true
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "this" {
  name        = "${var.name}-db"
  description = "PostgreSQL: clients only"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "clients" {
  # count, not for_each: the ids are only known after apply, the count is known now.
  count                        = length(var.client_security_group_ids)
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = var.client_security_group_ids[count.index]
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from app"
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.name}-pg${var.engine_version}"
  family = "postgres${var.engine_version}"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "500" # log statements slower than 500 ms
  }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-pg"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name                     = var.database_name
  username                    = "jobapply_admin"
  manage_master_user_password = true # generated; stored and rotated by RDS in Secrets Manager

  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period    = var.backup_retention_days
  backup_window              = "07:00-08:00" # UTC
  maintenance_window         = "sun:08:30-sun:09:30"
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-pg-final"

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  enabled_cloudwatch_logs_exports       = ["postgresql"]
}

output "address" { value = aws_db_instance.this.address }
output "port" { value = aws_db_instance.this.port }
output "database_name" { value = aws_db_instance.this.db_name }
output "username" { value = aws_db_instance.this.username }
output "master_secret_arn" { value = aws_db_instance.this.master_user_secret[0].secret_arn }
output "instance_id" { value = aws_db_instance.this.identifier }
output "security_group_id" { value = aws_security_group.this.id }
