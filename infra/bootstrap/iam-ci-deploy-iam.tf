# PowerUserAccess excludes IAM writes, but the app infra creates/manages its own
# IAM roles (ECS task execution/task roles) and must pass them to ECS. Grant
# IAM role management scoped to this project's role names + PassRole + the ECS/ELB
# service-linked roles.
#
# The permission-granting actions are split from the read/tag ones so they can
# carry an `iam:PermissionsBoundary` condition (ADR-0027 第1層, #656): without it
# ci_deploy could attach AdministratorAccess to any `${var.project}-*` role --
# including its own, since `${var.project}-<suffix>-ci-deploy` matches that
# pattern -- and reach account admin in one call. See iam-app-role-boundary.tf
# for the full escalation path and the ceiling that now caps it.
#
# PassRole is split into its own statement (rather than folded into
# ManageProjectRoles) so it can carry an iam:PassedToService condition (#45):
# without it, this role could pass any ${var.project}-* role to *any* AWS
# service that supports PassRole, not just the services this project's own
# assume-role trust policies actually expect (ecs-tasks.amazonaws.com,
# shared.tf; lambda.amazonaws.com, worker.tf's worker_lambda_assume, #640).
# iam:PassedToService is only present in the request context for PassRole
# calls, so it can't be added to a statement that also grants
# CreateRole/AttachRolePolicy/etc.
locals {
  # Account-scoped (#656). IAM calls only ever act on the caller's own account,
  # so the previous `arn:aws:iam::*:role/...` was wider than it read -- narrowed
  # while this statement was being rewritten anyway.
  project_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-*"
}

data "aws_iam_policy_document" "ci_deploy_iam" {
  statement {
    # Read + tag + delete: none of these can grant a permission, so they stay
    # unconditioned. DeleteRole in particular must keep working against roles
    # that predate the boundary, otherwise `terraform destroy` of an older
    # environment would strand its roles.
    sid    = "InspectAndTagProjectRoles"
    effect = "Allow"
    actions = [
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListAttachedRolePolicies",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListRoleTags",
      # The provider checks for attached instance profiles before DeleteRole;
      # without this the sandbox destroy failed at the two ECS roles (#258).
      "iam:ListInstanceProfilesForRole",
    ]
    resources = [local.project_role_arn]
  }

  # The permission-granting half. `iam:PermissionsBoundary` means different
  # things per action and both readings are needed here (AWS IAM user guide,
  # "Delegating responsibility to others using permissions boundaries"):
  #
  #   - CreateRole / PutRolePermissionsBoundary -> the boundary being SET by
  #     this request. Forces every new role to be born capped, and lets an
  #     existing un-boundaried role be brought under the boundary.
  #   - AttachRolePolicy / PutRolePolicy / DetachRolePolicy / DeleteRolePolicy
  #     -> the boundary CURRENTLY ON the target role. This is what denies the
  #     self-attach: ci_deploy has no boundary of its own, so it cannot modify
  #     its own permissions (nor ci_plan's or agent_mcp's).
  #
  # The second reading is also why migrating an existing environment has an
  # ordering requirement: until PutRolePermissionsBoundary has run against a
  # pre-existing role, every policy change on that role is denied. Terraform
  # gets this right on its own because aws_iam_role_policy / attachment
  # resources depend on the role, so the role update (which sets the boundary)
  # is applied first -- verified on a real environment before relying on it
  # (ADR-0027's verification requirement).
  statement {
    sid    = "ChangeProjectRolePermissionsOnlyWithBoundary"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = [local.project_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.app_role_boundary.arn]
    }
  }

  statement {
    # Removing the boundary would restore the escalation path in one call, so it
    # is denied outright rather than merely left ungranted -- an explicit Deny
    # survives any future policy addition to this role.
    sid       = "DenyBoundaryRemoval"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }

  statement {
    # Same reasoning one level up: a ceiling its own subject can rewrite is not a
    # ceiling. ci_deploy is not granted these actions anywhere today; this keeps
    # that true even if some future policy grants them.
    sid    = "DenyBoundaryPolicyTampering"
    effect = "Deny"
    actions = [
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
    ]
    resources = [aws_iam_policy.app_role_boundary.arn]
  }

  statement {
    # Blocks multi-hop assume, so a compromised deploy session cannot pivot into
    # another role in the account. Same statement as iam-agent-mcp.tf's
    # `agent_mcp_guardrails`, and safe here because nothing in the pipeline
    # chains roles: every job takes its credentials straight from the GitHub
    # OIDC token via AssumeRoleWithWebIdentity, a call made by the GitHub
    # principal rather than by this role.
    sid    = "DenyAssumeRole"
    effect = "Deny"
    actions = [
      "sts:AssumeRole",
      "sts:AssumeRoleWithWebIdentity",
      "sts:AssumeRoleWithSAML",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "PassProjectRolesToOwnServices"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [local.project_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com", "lambda.amazonaws.com"]
    }
  }

  # Service-linked roles are created on the caller's behalf the first time a
  # service is used in an account, so ci_deploy needs CreateServiceLinkedRole --
  # but it used to carry Resource "*" with no condition, which made it the
  # single broadest grant on the role (any AWS service's SLR, not just the ones
  # this stack uses). Scoped to the aws-service-role path plus an explicit
  # iam:AWSServiceName allowlist derived from the resources declared in
  # infra/*.tf (#651).
  #
  # A missing entry surfaces as AccessDenied on the *first* apply in a fresh
  # account only -- once an SLR exists, the service stops asking for it -- so a
  # gap here is invisible in any environment that has already been created once.
  statement {
    sid       = "ServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::*:role/aws-service-role/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "ecs.amazonaws.com",                         # aws_ecs_cluster / aws_ecs_service (api.tf)
        "elasticloadbalancing.amazonaws.com",        # aws_lb (api.tf)
        "ecs.application-autoscaling.amazonaws.com", # aws_appautoscaling_target (api.tf)
        "rds.amazonaws.com",                         # aws_db_instance (db.tf)
        # aws_ecr_pull_through_cache_rule.ecr_public (endpoints.tf, #598):
        # creating a pull through cache rule makes ECR create
        # AWSServiceRoleForECRPullThroughCache on the caller's behalf
        # ("Amazon ECR service-linked role for pull through cache" in the ECR
        # user guide). Not in the original #651 audit list, which was derived
        # from compute/db resources only -- the #598 sandbox run passed because
        # the grant was still unconditional at the time.
        "pullthroughcache.ecr.amazonaws.com",
      ]
    }
  }

  statement {
    # infra/shared.tf reads the boundary ARN from this parameter rather than
    # deriving it, because the policy name carries the bootstrap's random suffix
    # (iam-app-role-boundary.tf). The ARN pins account and region, so no
    # aws:RequestedRegion condition is needed on top of it.
    sid       = "ReadBootstrapPublishedParameters"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [aws_ssm_parameter.app_role_boundary_arn.arn]
  }
}
