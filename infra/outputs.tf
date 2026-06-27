output "account_id" {
  description = "AWS account ID the configuration is deployed into."
  value       = data.aws_caller_identity.current.account_id
}

output "region" {
  description = "AWS region in use."
  value       = data.aws_region.current.name
}

output "name_prefix" {
  description = "Common prefix for resource naming."
  value       = local.name_prefix
}

output "web_bucket" {
  description = "S3 bucket hosting the built SPA."
  value       = aws_s3_bucket.web.id
}

output "ecr_repository_url" {
  description = "ECR repository URL for the api image."
  value       = aws_ecr_repository.api.repository_url
}

output "log_group_name" {
  description = "Shared CloudWatch log group."
  value       = aws_cloudwatch_log_group.app.name
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets."
  value       = aws_subnet.private[*].id
}

output "app_security_group_id" {
  description = "Security group ID attached by the future ECS/api tasks."
  value       = aws_security_group.app.id
}

output "db_endpoint" {
  description = "Connection address (host) of the RDS PostgreSQL instance."
  value       = aws_db_instance.postgres.address
  sensitive   = true
}

output "db_port" {
  description = "Port the RDS PostgreSQL instance listens on."
  value       = aws_db_instance.postgres.port
}

output "db_name" {
  description = "Name of the initial application database."
  value       = aws_db_instance.postgres.db_name
}

output "db_master_secret_arn" {
  description = "ARN of the RDS-managed master credentials secret in Secrets Manager."
  value       = aws_db_instance.postgres.master_user_secret[0].secret_arn
  sensitive   = true
}
