#############################################
# CI IAM roles assumed via OIDC
#############################################
# Trust policies + the plan/deploy role shells themselves. The deploy role's
# least-privilege domain policies (network/compute/storage_cdn/data/auth/
# observability/iam) each live in their own iam-ci-deploy-*.tf file -- see
# locals.tf for the rationale behind that split.

# Trust policy template: only this repo, only the GitHub OIDC provider, and a restricted
# set of `sub` claims (PR vs. main/production), each listed in both known GitHub `sub`
# formats (classic and owner_id/repository_id-embedded, see `local.plan_subjects` /
# `local.deploy_subjects` above -- #581).
data "aws_iam_policy_document" "plan_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.plan_subjects
    }
  }
}

data "aws_iam_policy_document" "deploy_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.deploy_subjects
    }
  }
}

# Read-only PLAN role (PRs): enough to run `terraform plan` and read state.
resource "aws_iam_role" "ci_plan" {
  name               = "${local.name_prefix}-ci-plan"
  assume_role_policy = data.aws_iam_policy_document.plan_assume_role.json
  description        = "Read-only role assumed by PR pipelines to run terraform plan."
}

# AWS-managed broad read-only access keeps plan honest without granting writes.
resource "aws_iam_role_policy_attachment" "ci_plan_readonly" {
  role       = aws_iam_role.ci_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# IAM Access Analyzer's ValidatePolicy (#340) statically checks a rendered IAM
# policy document for structural issues (e.g. condition keys that don't exist
# for the paired action -- the exact bug class in #338) without attaching or
# using the policy. It doesn't target any resource ARN -- the policy document
# is passed as a request argument -- so Resource "*" is the only valid scope,
# and the call is read-only with no side effects. Granted explicitly rather
# than relying on ReadOnlyAccess covering it implicitly (#45's least-privilege
# posture: prefer an explicit, documented grant over an assumption about what
# a broad AWS-managed policy happens to include).
data "aws_iam_policy_document" "ci_plan_access_analyzer" {
  statement {
    sid       = "ValidateIamPolicies"
    effect    = "Allow"
    actions   = ["access-analyzer:ValidatePolicy"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ci_plan_access_analyzer" {
  name   = "access-analyzer-validate-policy"
  role   = aws_iam_role.ci_plan.id
  policy = data.aws_iam_policy_document.ci_plan_access_analyzer.json
}

# Plan (PRs) only ever runs against the `dev` key (cd-infra.yml hardcodes
# TF_ENV=dev for the plan job; prod/sandbox are only ever touched via the
# DEPLOY role). Scope ci_plan's state access to that one key so a PR-triggered
# plan can never read, overwrite, or delete prod/sandbox state (#45, #153
# finding: the plan role previously shared the DEPLOY role's bucket-wide
# read/write policy).
data "aws_iam_policy_document" "tfstate_access_plan" {
  statement {
    sid       = "StateBucketListDevOnly"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.project}/dev/*"]
    }
  }

  statement {
    sid       = "StateObjectReadDevOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/${var.project}/dev/terraform.tfstate"]
  }

  # S3-native state locking (use_lockfile): the lock is a `<key>.tflock`
  # object in the same bucket. `plan` must still acquire/release this lock to
  # safely read state, but (unlike `apply`) never needs to write the state
  # object itself -- so Put/Delete is scoped to the lock file only, not the
  # real state object.
  statement {
    sid       = "StateLockRWDevOnly"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/${var.project}/dev/terraform.tfstate.tflock"]
  }
}

resource "aws_iam_role_policy" "ci_plan_state" {
  name   = "tfstate-access-dev"
  role   = aws_iam_role.ci_plan.id
  policy = data.aws_iam_policy_document.tfstate_access_plan.json
}

# DEPLOY role (push to main / production env): can apply app infra against
# any environment key (prod via cd-infra.yml's manual apply, sandbox via
# cd-infra-sandbox.yml) -- genuinely needs read/write across the whole
# bucket, unlike the plan role above.
data "aws_iam_policy_document" "tfstate_access_deploy" {
  statement {
    sid       = "StateBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  # S3-native state locking (use_lockfile): the lock is a `<key>.tflock` object
  # in the same bucket, so object read/write/delete also covers acquiring and
  # releasing the lock.
  statement {
    sid       = "StateObjectRW"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

resource "aws_iam_role" "ci_deploy" {
  name               = "${local.name_prefix}-ci-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_assume_role.json
  description        = "Role assumed on merge to main to apply infra and deploy the app."
}

resource "aws_iam_policy" "ci_deploy_state" {
  name   = "${local.name_prefix}-deploy-tfstate-access"
  policy = data.aws_iam_policy_document.tfstate_access_deploy.json
}

resource "aws_iam_role_policy_attachment" "ci_deploy_state" {
  role       = aws_iam_role.ci_deploy.name
  policy_arn = aws_iam_policy.ci_deploy_state.arn
}
