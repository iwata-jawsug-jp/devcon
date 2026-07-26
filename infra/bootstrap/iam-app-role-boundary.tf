# Permissions boundary for the IAM roles ci_deploy creates in the app layer
# (infra/shared.tf's ECS task / task execution roles). ADR-0027 第1層, #656.
#
# WHY THIS EXISTS
#
# `ManageProjectRoles` (iam-ci-deploy-iam.tf) lets ci_deploy create and attach
# policies to any `${var.project}-*` role. ci_deploy's OWN role name --
# `${var.project}-${var.resource_name_suffix}-ci-deploy`, see locals.tf --
# matches that pattern, so before this file existed a single
# `AttachRolePolicy AdministratorAccess` against itself was enough to reach
# account-wide admin (same for `-ci-plan` and `-agent-mcp`, whose
# `agent_mcp_guardrails` Deny statements could simply be replaced). The longer
# route -- CreateRole(trust: ecs-tasks) -> AttachRolePolicy -> PassRole ->
# RegisterTaskDefinition + RunTask -- reached the same place. In other words the
# permissions ci_deploy could *reach* were wider than the ones it was *granted*.
#
# The fix is AWS's documented delegation pattern ("Delegating responsibility to
# others using permissions boundaries"): iam-ci-deploy-iam.tf now only allows
# role creation / policy attachment when the target role carries exactly this
# boundary. ci_deploy itself has no boundary, so the self-attach is denied
# outright; a role it does create can never exceed the ceiling below no matter
# which policy is attached to it.
#
# A CEILING, NOT A GRANT
#
# Effective permissions of a boundaried role are the intersection of its
# identity policies and this document, so this is deliberately generous inside
# the project's region and hard-stopped outside it. The app roles' real
# least-privilege lives in their own identity policies (infra/shared.tf: ECR
# pull, CloudWatch Logs, the RDS-managed secret). A boundary that also tried to
# be least-privilege would break the app every time a feature needs one more
# API -- the exact failure mode ADR-0027 flags as requiring live verification
# ("境界がアプリ側ロールを絞りすぎないこと").
#
# The `-boundary` name suffix is load-bearing: ADR-0027 第2層 (#658) exempts
# boundary policies from `infra/policy/iam_wildcard.rego` by that suffix, since
# `Action: "*"` is normal for a ceiling but banned in a grant.
data "aws_iam_policy_document" "app_role_boundary" {
  statement {
    sid       = "AllowWithinProjectRegion"
    effect    = "Allow"
    actions   = ["*"]
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

  statement {
    # Insurance, not baseline -- IAM / Organizations / account are global, so
    # they already fall outside the regional Allow above (their requests do not
    # carry this project's aws:RequestedRegion). Stating the deny explicitly
    # keeps the ceiling's intent readable and survives any future widening of
    # the Allow statement. Same reasoning as iam-agent-mcp.tf's
    # `DenyDestructiveActions`.
    #
    # sts:AssumeRole* blocks role chaining: a boundaried app role must not be
    # able to pivot into some other role that has no boundary. ECS assuming the
    # task role is unaffected -- that call is authorized by the role's trust
    # policy against the ecs-tasks service principal, and a permissions boundary
    # never applies to who may assume the role, only to what the role can do.
    sid    = "DenyPrivilegeEscalationAndPivot"
    effect = "Deny"
    actions = [
      "iam:*",
      "organizations:*",
      "account:*",
      "sts:AssumeRole",
      "sts:AssumeRoleWithSAML",
      "sts:AssumeRoleWithWebIdentity",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "app_role_boundary" {
  name        = "${local.name_prefix}-app-role-boundary"
  description = "Permissions boundary required on every ${var.project}-* role ci_deploy creates (ADR-0027 第1層)."
  policy      = data.aws_iam_policy_document.app_role_boundary.json
}

# Handoff to the app layer. infra/shared.tf must set `permissions_boundary` on
# the roles it creates, but it cannot derive this ARN: the policy name carries
# `var.resource_name_suffix` (locals.tf) precisely so a re-bootstrap after a lost
# local state always lands on a fresh, unclaimed name. Publishing the ARN at a
# deterministic, project-scoped SSM path keeps that property while letting the
# app layer read it with a plain data source -- no repo variable, no workflow
# plumbing, and `terraform plan` works locally too.
#
# `overwrite = true` is what preserves the re-bootstrap property for the
# parameter itself: without it a second bootstrap into an account that still has
# the old parameter fails with ParameterAlreadyExists.
resource "aws_ssm_parameter" "app_role_boundary_arn" {
  name        = "/${var.project}/bootstrap/app-role-boundary-arn"
  description = "ARN of the permissions boundary the app layer must attach to the roles it creates (ADR-0027 第1層, #656)."
  type        = "String"
  value       = aws_iam_policy.app_role_boundary.arn
  overwrite   = true
}
