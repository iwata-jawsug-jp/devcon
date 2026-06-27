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
