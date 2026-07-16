output "state_bucket_name" {
  description = "S3 bucket holding Terraform remote state (also used for native state locking)."
  value       = aws_s3_bucket.state.id
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider (created by this bootstrap, or an existing one reused when create_oidc_provider = false)."
  value       = local.oidc_provider_arn
}

output "ci_plan_role_arn" {
  description = "Read-only role assumed by PR pipelines (terraform plan)."
  value       = aws_iam_role.ci_plan.arn
}

output "ci_deploy_role_arn" {
  description = "Deploy role assumed on merge to main (terraform apply / app deploy)."
  value       = aws_iam_role.ci_deploy.arn
}
