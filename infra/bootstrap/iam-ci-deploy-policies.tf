# Managed policies attached to ci_deploy (#652).
#
# WHY THE GROUPING EXISTS
#
# IAM allows 10 managed policies per role. One policy per area file put the role at 9/10 --
# one more area (EventBridge, API Gateway, Step Functions, ... as #641's Go services land)
# and `infra/bootstrap` stops applying. The quota is raisable to 25 via Service Quotas, but
# this repo is a copier scaffold (#294, ADR-0010/0011): a per-account manual quota request
# would break "fresh clone, `infra/bootstrap` applies as-is".
#
# So the *policy documents* stay one-per-area -- iam-ci-deploy-<area>.tf keeps its
# `data "aws_iam_policy_document"`, which is the review unit and where every action's
# justifying comment lives -- and only the `aws_iam_policy` resources merge, via
# `source_policy_documents`. Nothing about the effective permissions changes: the merged
# document is the concatenation of the same statements, each keeping its Sid (all Sids
# across bootstrap are unique, so nothing collides and CloudTrail-based diagnosis still
# points at a named statement).
#
# SIZES AT THE TIME OF WRITING (rendered JSON chars; managed-policy quota is 6,144 each)
#
#   compute 3,088 | manage-project-iam 2,032 | data 1,677 | network 1,408
#   storage-cdn 1,334 | auth 1,070 | messaging 772 | observability 521 | tfstate 334
#   total 12,236 across 9 policies
#
# Those numbers are post-ADR-0027: 第2層 (#658) cut 2,889 chars by collapsing enumerated
# actions on ARN-scoped statements into service wildcards, and 第1層 (#656) grew
# manage-project-iam from 758 to 2,032 with the permissions-boundary conditions. The
# grouping below is balanced for *those* sizes -- re-measure before assuming it still
# holds if either layer is revisited.
#
# Groups are chosen to be semantically defensible as well as balanced, so a reader can
# guess which policy holds a given permission:
#
#   deploy-platform   network + manage-project-iam + tfstate   3,698  (60%)  VPC, IAM, state
#   deploy-runtime    compute + observability                  3,571  (58%)  runtime + telemetry
#   deploy-datastore  data + messaging                         2,411  (39%)  persistence + async
#   deploy-edge       storage-cdn + auth                       2,366  (39%)  SPA/CDN + Cognito
#
# NONE OF THESE NAMES MAY MATCH A PRE-#652 POLICY NAME. Terraform has no ordering
# relationship between creating aws_iam_policy.ci_deploy[<key>] and destroying the old
# per-area aws_iam_policy.ci_deploy_<area>, so reusing `deploy-compute`/`deploy-data` made the create
# fail with EntityAlreadyExists *after* the old attachments were already gone -- observed
# for real while applying this change, leaving ci_deploy with zero policies until a second
# apply. Downstream projects apply this same transition from the same 9-policy starting
# point, so the names have to be new ones: `deploy-runtime`/`deploy-datastore` rather than
# `deploy-compute`/`deploy-data`.
#
# 9 attachments -> 4, i.e. 6 free slots, and every group has 2,300+ chars of headroom.
# Three groups would also fit today (max would be ~71%), but four keeps room for the next
# area file without another regrouping.
#
# A permissions boundary does NOT consume this quota -- measured on a throwaway role during
# #652: with `app_role_boundary` attached as the boundary, 10 managed policies still
# attached fine and the 11th failed with `LimitExceeded: PoliciesPerRole: 10`. ADR-0027
# flagged this as unverified for its 第3層; it is now answered.
#
# NOTE FOR CHANGES: `tools/script/bootstrap.sh`'s `recover` path hardcodes these policy
# names so a lost local state can be rebuilt by import -- update its `ci_deploy_policy_keys`
# array together with `local.ci_deploy_policies` below.

data "aws_iam_policy_document" "ci_deploy_platform" {
  source_policy_documents = [
    data.aws_iam_policy_document.ci_deploy_network.json,
    data.aws_iam_policy_document.ci_deploy_iam.json,
    data.aws_iam_policy_document.tfstate_access_deploy.json,
  ]
}

data "aws_iam_policy_document" "ci_deploy_compute_all" {
  source_policy_documents = [
    data.aws_iam_policy_document.ci_deploy_compute.json,
    data.aws_iam_policy_document.ci_deploy_observability.json,
  ]
}

data "aws_iam_policy_document" "ci_deploy_data_all" {
  source_policy_documents = [
    data.aws_iam_policy_document.ci_deploy_data.json,
    data.aws_iam_policy_document.ci_deploy_messaging.json,
  ]
}

data "aws_iam_policy_document" "ci_deploy_edge" {
  source_policy_documents = [
    data.aws_iam_policy_document.ci_deploy_storage_cdn.json,
    data.aws_iam_policy_document.ci_deploy_auth.json,
  ]
}

locals {
  # Keyed by the name suffix so the resource address, the policy name and bootstrap.sh's
  # recovery map stay in step.
  ci_deploy_policies = {
    "deploy-platform"  = data.aws_iam_policy_document.ci_deploy_platform.json
    "deploy-runtime"   = data.aws_iam_policy_document.ci_deploy_compute_all.json
    "deploy-datastore" = data.aws_iam_policy_document.ci_deploy_data_all.json
    "deploy-edge"      = data.aws_iam_policy_document.ci_deploy_edge.json
  }
}

resource "aws_iam_policy" "ci_deploy" {
  for_each = local.ci_deploy_policies

  name   = "${local.name_prefix}-${each.key}"
  policy = each.value

  lifecycle {
    precondition {
      # Fail in `terraform plan` rather than as an opaque AWS error at apply time (#652's
      # 案B). 6,144 is the per-managed-policy character quota; 90% leaves room for the
      # apply to still succeed while flagging that this group needs re-splitting.
      condition     = length(each.value) < 5530
      error_message = "Managed policy ${each.key} renders to ${length(each.value)} chars, over 90% of IAM's 6,144 quota -- re-split the groups in iam-ci-deploy-policies.tf."
    }
  }
}

resource "aws_iam_role_policy_attachment" "ci_deploy" {
  for_each = local.ci_deploy_policies

  role       = aws_iam_role.ci_deploy.name
  policy_arn = aws_iam_policy.ci_deploy[each.key].arn
}
