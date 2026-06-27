# RDS for PostgreSQL: single instance in the private subnets.
#
# The master password is managed by RDS (stored in Secrets Manager) — never set
# in Terraform. Env-specific tunables (multi-AZ, deletion protection, final
# snapshot, instance size) keep dev cheap and prod hardened.

resource "aws_db_subnet_group" "postgres" {
  name       = "${local.name_prefix}-postgres"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${local.name_prefix}-postgres"
  }
}

resource "aws_db_instance" "postgres" {
  identifier = "${local.name_prefix}-postgres"

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username

  # RDS-managed master credentials in Secrets Manager (no password in state).
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.postgres.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  multi_az                            = var.db_multi_az
  backup_retention_period             = var.db_backup_retention
  auto_minor_version_upgrade          = true
  iam_database_authentication_enabled = true
  copy_tags_to_snapshot               = true
  performance_insights_enabled        = true
  enabled_cloudwatch_logs_exports     = ["postgresql"]

  deletion_protection = var.db_deletion_protection
  skip_final_snapshot = var.db_skip_final_snapshot
  final_snapshot_identifier = (
    var.db_skip_final_snapshot ? null : "${local.name_prefix}-postgres-final"
  )
  apply_immediately = false
}
