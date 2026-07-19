variable "project" {
  description = "Project name, used for tagging and resource naming."
  type        = string
  default     = "devcon"
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-northeast-1"
}

variable "github_org" {
  description = "GitHub organization (or user) that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (without the org prefix)."
  type        = string
}

variable "state_bucket_name" {
  description = "Globally-unique S3 bucket name for Terraform remote state."
  type        = string
}

variable "resource_name_suffix" {
  description = <<-EOT
    Short random token (same one used to build state_bucket_name, e.g. its trailing
    "-<random6>") appended to every bootstrap-managed IAM role/policy name
    ("$${project}-$${resource_name_suffix}-ci-plan", etc.). Without this, re-running
    `init` after the local state that tracked a prior apply was lost/discarded hits
    EntityAlreadyExists against the still-existing AWS-side IAM roles/policies from that
    prior attempt -- a fresh suffix per `init` guarantees a fresh, unclaimed name instead.
    Required (no default): generated once by tools/script/bootstrap.sh init and persisted
    in terraform.auto.tfvars.
  EOT
  type        = string
}

variable "create_oidc_provider" {
  description = <<-EOT
    Whether to create the GitHub Actions OIDC provider (token.actions.githubusercontent.com).
    IAM allows only one OIDC provider per URL per AWS account, so in an account shared by
    multiple repos/projects a prior bootstrap may have already created it -- creating a
    second one fails with EntityAlreadyExists. Set to false to look up and reuse the
    existing provider instead (tools/script/bootstrap.sh init auto-detects this).
  EOT
  type        = bool
  default     = true
}
