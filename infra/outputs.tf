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

output "ecs_cluster_name" {
  description = "ECS cluster name (cd-app ECS_CLUSTER)."
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS service name (cd-app ECS_SERVICE)."
  value       = aws_ecs_service.api.name
}

output "ecs_task_family" {
  description = "api task definition family (cd-app re-registers revisions of this)."
  value       = aws_ecs_task_definition.api.family
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (cd-app CLOUDFRONT_DISTRIBUTION_ID)."
  value       = aws_cloudfront_distribution.web.id
}

output "cloudfront_domain_name" {
  description = "CloudFront domain name (public URL of the app)."
  value       = aws_cloudfront_distribution.web.domain_name
}

output "alb_dns_name" {
  description = "Public DNS name of the api ALB."
  value       = aws_lb.api.dns_name
}

output "sns_alerts_topic_arn" {
  description = "SNS topic ARN that CloudWatch alarms notify (observability.tf, #42)."
  value       = aws_sns_topic.alerts.arn
}

output "cloudwatch_dashboard_url" {
  description = "Console URL of the observability dashboard (observability.tf, #42)."
  value       = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

# --- Cognito (authn/authz, Issue #41) ---
# Non-sensitive identifiers only: the app client is public (generate_secret =
# false), so there is no client secret to ever output. `region` above already
# covers the region identifier consumed alongside these.

output "cognito_user_pool_id" {
  description = "Cognito user pool ID (API: JWT `iss` verification; frontend: oidc-client-ts authority)."
  value       = aws_cognito_user_pool.users.id
}

output "cognito_user_pool_client_id" {
  description = "Cognito app client ID (public client, no secret)."
  value       = aws_cognito_user_pool_client.web.id
}

output "cognito_hosted_ui_domain" {
  description = "Fully-qualified Cognito Hosted UI domain (Cognito-prefix, no ACM cert)."
  value       = "https://${aws_cognito_user_pool_domain.hosted_ui.domain}.auth.${var.aws_region}.amazoncognito.com"
}
