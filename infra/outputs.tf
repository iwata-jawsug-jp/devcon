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
