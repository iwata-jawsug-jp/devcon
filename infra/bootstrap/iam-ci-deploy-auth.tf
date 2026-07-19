# Auth (auth.tf, #41): Cognito user pool + resource server + client + Hosted
# UI domain. Unlike ECR/ECS/RDS above, none of these resource types have a
# project-controlled name we can put in the ARN (the pool ID is an opaque
# value AWS assigns on creation, so CreateUserPool -- and everything scoped
# under a specific pool -- can't be resource-scoped the way e.g. ECR
# repositories are). No condition key exists to narrow this further, so this
# is Resource "*" like the other no-resource-level-support cases above (ELB,
# Application Auto Scaling, CloudFront) (#258).
data "aws_iam_policy_document" "ci_deploy_auth" {
  statement {
    sid    = "Cognito"
    effect = "Allow"
    actions = [
      "cognito-idp:CreateUserPool",
      "cognito-idp:DeleteUserPool",
      "cognito-idp:DescribeUserPool",
      "cognito-idp:UpdateUserPool",
      # The AWS provider reads MFA config as part of managing
      # aws_cognito_user_pool, even though this project never sets it (#258).
      "cognito-idp:GetUserPoolMfaConfig",
      "cognito-idp:TagResource",
      "cognito-idp:UntagResource",
      "cognito-idp:ListTagsForResource",
      "cognito-idp:CreateResourceServer",
      "cognito-idp:DeleteResourceServer",
      "cognito-idp:DescribeResourceServer",
      "cognito-idp:UpdateResourceServer",
      "cognito-idp:CreateUserPoolClient",
      "cognito-idp:DeleteUserPoolClient",
      "cognito-idp:DescribeUserPoolClient",
      "cognito-idp:UpdateUserPoolClient",
      "cognito-idp:CreateUserPoolDomain",
      "cognito-idp:DeleteUserPoolDomain",
      "cognito-idp:DescribeUserPoolDomain",
    ]
    resources = ["*"]

    dynamic "condition" {
      for_each = [local.region_condition]
      content {
        test     = condition.value.test
        variable = condition.value.variable
        values   = condition.value.values
      }
    }
  }

  # Per-run disposable test users for the live-browser E2E smoke gate (#376,
  # ADR-0008): the smoke-test job creates a throwaway Cognito user, logs in
  # as it, then deletes it -- no fixed pre-provisioned user to re-register by
  # hand every time sandbox infra is rebuilt. Unlike the pool-management
  # actions above, these DO support resource-level scoping to a userpool
  # ARN; still Resource "*" for the pool-id segment specifically (this
  # bootstrap layer is applied before the app layer creates the actual pool
  # -- see auth.tf -- so no concrete pool ID exists here to reference), but
  # narrowed to the cognito-idp userpool resource type, same pattern as the
  # ECR/ECS/RDS statements above.
  statement {
    sid    = "CognitoAdminUsers"
    effect = "Allow"
    actions = [
      "cognito-idp:AdminCreateUser",
      "cognito-idp:AdminSetUserPassword",
      "cognito-idp:AdminDeleteUser",
    ]
    resources = ["arn:aws:cognito-idp:*:*:userpool/*"]

    dynamic "condition" {
      for_each = [local.region_condition]
      content {
        test     = condition.value.test
        variable = condition.value.variable
        values   = condition.value.values
      }
    }
  }
}

resource "aws_iam_policy" "ci_deploy_auth" {
  name   = "${local.name_prefix}-deploy-auth"
  policy = data.aws_iam_policy_document.ci_deploy_auth.json
}

resource "aws_iam_role_policy_attachment" "ci_deploy_auth" {
  role       = aws_iam_role.ci_deploy.name
  policy_arn = aws_iam_policy.ci_deploy_auth.arn
}
