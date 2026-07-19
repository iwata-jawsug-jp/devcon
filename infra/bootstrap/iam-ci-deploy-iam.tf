# PowerUserAccess excludes IAM writes, but the app infra creates/manages its own
# IAM roles (ECS task execution/task roles) and must pass them to ECS. Grant
# IAM role management scoped to this project's role names + PassRole + the ECS/ELB
# service-linked roles.
#
# PassRole is split into its own statement (rather than folded into
# ManageProjectRoles) so it can carry an iam:PassedToService condition (#45):
# without it, this role could pass any ${var.project}-* role to *any* AWS
# service that supports PassRole, not just the ECS tasks service that
# shared.tf's ecs_assume trust policy actually expects
# (principals { type = "Service", identifiers = ["ecs-tasks.amazonaws.com"] }).
# iam:PassedToService is only present in the request context for PassRole
# calls, so it can't be added to a statement that also grants
# CreateRole/AttachRolePolicy/etc.
data "aws_iam_policy_document" "ci_deploy_iam" {
  statement {
    sid    = "ManageProjectRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListRoleTags",
      # The provider checks for attached instance profiles before DeleteRole;
      # without this the sandbox destroy failed at the two ECS roles (#258).
      "iam:ListInstanceProfilesForRole",
    ]
    resources = ["arn:aws:iam::*:role/${var.project}-*"]
  }
  statement {
    sid       = "PassProjectRolesToEcsTasks"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::*:role/${var.project}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
  statement {
    sid       = "ServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ci_deploy_iam" {
  name   = "${local.name_prefix}-manage-project-iam"
  policy = data.aws_iam_policy_document.ci_deploy_iam.json
}

resource "aws_iam_role_policy_attachment" "ci_deploy_iam" {
  role       = aws_iam_role.ci_deploy.name
  policy_arn = aws_iam_policy.ci_deploy_iam.arn
}
