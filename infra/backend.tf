# Remote state backend.
#
# Uncomment and fill in once the S3 bucket + DynamoDB lock table exist, then run
# `terraform init -migrate-state`. Values cannot use variables, so set the bucket
# per environment with `-backend-config` or a `*.backend.hcl` file:
#
#   terraform init -backend-config=env/dev.backend.hcl
#
# terraform {
#   backend "s3" {
#     bucket         = "REPLACE-ME-tfstate"
#     key            = "devcon/terraform.tfstate"
#     region         = "ap-northeast-1"
#     dynamodb_table = "REPLACE-ME-tflock"
#     encrypt        = true
#   }
# }
