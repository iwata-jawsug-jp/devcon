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

output "agent_mcp_role_arn" {
  description = "Read-only role assumed locally via the AWS MCP Server (Claude Code); not used by CI."
  value       = aws_iam_role.agent_mcp.arn
}

output "app_role_boundary_arn" {
  description = "Permissions boundary the app layer must attach to every role it creates (ADR-0027 第1層). Also published to SSM at /<project>/bootstrap/app-role-boundary-arn, which is how infra/shared.tf actually reads it -- this output is for humans and for `terraform output` based checks."
  value       = aws_iam_policy.app_role_boundary.arn
}

output "resource_name_suffix" {
  description = "Pass-through of var.resource_name_suffix, so tools/script/bootstrap.sh can recover it via `terraform output` if terraform.auto.tfvars is lost but local state survives."
  value       = var.resource_name_suffix
}
