output "state_bucket_name" {
  description = "S3 bucket holding Terraform remote state."
  value       = aws_s3_bucket.state.id
}

output "lock_table_name" {
  description = "DynamoDB table used for Terraform state locking."
  value       = aws_dynamodb_table.lock.name
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "ci_plan_role_arn" {
  description = "Read-only role assumed by PR pipelines (terraform plan)."
  value       = aws_iam_role.ci_plan.arn
}

output "ci_deploy_role_arn" {
  description = "Deploy role assumed on merge to main (terraform apply / app deploy)."
  value       = aws_iam_role.ci_deploy.arn
}
