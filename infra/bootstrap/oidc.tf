#############################################
# GitHub Actions OIDC provider
#############################################

# See create_oidc_provider's description (variables.tf) for why this is conditional.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Refactor from an unconditional resource to count-based (#491): keeps this
# resource's existing state address instead of planning a destroy+recreate.
moved {
  from = aws_iam_openid_connect_provider.github
  to   = aws_iam_openid_connect_provider.github[0]
}

# Looked up instead of created when create_oidc_provider = false.
data "aws_iam_openid_connect_provider" "existing_github" {
  count = var.create_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.existing_github[0].arn
}
