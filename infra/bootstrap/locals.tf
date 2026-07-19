# Shared locals referenced from multiple bootstrap files (split from the former
# single-file main.tf, #584): name_prefix/repo/plan_subjects/deploy_subjects feed
# oidc.tf and iam-ci-roles.tf; region_condition feeds every iam-ci-deploy-*.tf policy.

locals {
  # Shared prefix for every bootstrap-managed IAM role/policy name. The random suffix
  # (var.resource_name_suffix) guarantees a fresh, unclaimed name on every `init`, even
  # when a prior attempt's AWS-side IAM resources are still around because the local state
  # that tracked them was lost/discarded.
  name_prefix = "${var.project}-${var.resource_name_suffix}"

  repo = "${var.github_org}/${var.github_repo}"

  # GitHub's `sub` claim format is not stable across repos (#581): some repos emit the
  # classic `repo:<org>/<repo>:...` form, others an owner_id/repository_id embedded form
  # (`repo:<org>@<owner_id>/<repo>@<repo_id>:...`) for reasons GitHub does not document.
  # Each subject below is listed in both forms so either format is accepted.
  #
  # `sub` is the only claim used here -- and has to be, empirically: an earlier version of
  # this file tried moving the PR-vs-push-vs-environment distinction onto the `repository`/
  # `event_name`/`ref`/`environment` claims instead (kept `sub` only as a wide, mandatory
  # wildcard, see AWS's requirement below). `terraform apply` accepted that policy without
  # error, but real GitHub Actions runs then got `Not authorized to perform
  # sts:AssumeRoleWithWebIdentity` even though the token's `repository`/`event_name` values
  # matched exactly (confirmed by dumping the actual OIDC token in CI, #581) -- AWS IAM
  # evidently only extracts `sub`/`aud`/`job_workflow_ref` as usable condition keys for the
  # GitHub Actions OIDC provider (matching AWS's own `MalformedPolicyDocument` wording when
  # `sub` was dropped entirely: "must evaluate ... sub or job_workflow_ref"), silently
  # treating other claim names as absent -- which makes a `StringEquals` condition on them
  # always false. Confirmed fixed by reverting to `sub`-only conditions with both formats.
  plan_subjects = [
    "repo:${local.repo}:pull_request",
    "repo:${var.github_org}@*/${var.github_repo}@*:pull_request",
  ]
  deploy_subjects = [
    "repo:${local.repo}:ref:refs/heads/main",
    "repo:${local.repo}:environment:production",
    # Sandbox dev environment: any sandbox/* branch may assume the deploy role so
    # cd-infra-sandbox can verify `terraform apply`. Isolated by the sandbox guard
    # (sandbox/* never merges into main). See docs/sandbox.md.
    "repo:${local.repo}:ref:refs/heads/sandbox/*",
    "repo:${var.github_org}@*/${var.github_repo}@*:ref:refs/heads/main",
    "repo:${var.github_org}@*/${var.github_repo}@*:environment:production",
    "repo:${var.github_org}@*/${var.github_repo}@*:ref:refs/heads/sandbox/*",
  ]
}

# Least-privilege scoped policies (#45), replacing a prior PowerUserAccess
# attachment. Split by service group to keep each block reviewable, and
# attached as customer-managed policies (aws_iam_policy +
# aws_iam_role_policy_attachment) rather than inline (aws_iam_role_policy):
# a role's INLINE policies share one combined 10,240-byte quota, which this
# role hit once auth.tf/observability.tf coverage (#258) was added on top of
# the original #45 split -- each managed policy instead gets its own 6,144
# character quota, and a role can hold up to 10 of them. Resource ARNs are
# scoped to this project's
# naming (`${var.project}-*` / `/${var.project}/*`) everywhere AWS IAM
# supports resource-level restriction for the action; a handful of
# describe/list/create actions genuinely require Resource "*" because the
# service doesn't support resource-level permissions for them (called out
# per statement below). This was derived from the AWS resource types actually
# declared in infra/*.tf, not from CloudTrail access-history — validate with
# `terraform plan`/`apply` against a real environment before relying on it,
# and watch for AccessDenied errors on first use (see docs/infrastructure.md).
#
# Follow-up narrowing (#45): the statements below also add an
# `aws:RequestedRegion` condition (scoped to `var.aws_region`) on every
# genuinely regional service (EC2/ECS/ECR/RDS/CloudWatch Logs/ELB/Application
# Auto Scaling) — deliberately NOT on IAM, S3, or CloudFront, which are
# global or have unreliable aws:RequestedRegion support. The `elasticloadbalancing:*` /
# `application-autoscaling:*` / `cloudfront:*` action wildcards were narrowed
# to the enumerated actions the declared resource types actually need, and
# `iam:PassRole` was split into its own statement carrying an
# `iam:PassedToService` condition (`ecs-tasks.amazonaws.com` only).

# Single source for the `aws:RequestedRegion` condition repeated across the
# statements below (#285) -- previously 18 independent copies of the same
# 4-line block, which risked a region-scoping gap slipping in silently if
# only some copies were updated (e.g. adding a second region, or renaming the
# variable). Expanded into each statement via a `dynamic "condition"` block
# below instead of being copy-pasted.
locals {
  region_condition = {
    test     = "StringEquals"
    variable = "aws:RequestedRegion"
    values   = [var.aws_region]
  }
}
