terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # NOTE: bootstrap uses LOCAL state on purpose. It creates the S3 bucket +
  # DynamoDB table that the app-infra layer later uses as its remote backend,
  # so it cannot depend on that backend existing yet. Do NOT add a backend block.
}
