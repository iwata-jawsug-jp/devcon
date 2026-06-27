locals {
  # Subjects allowed to assume the CI roles, expressed as OIDC `sub` claims.
  repo = "${var.github_org}/${var.github_repo}"

  # PRs run the read-only plan role; pushes/merges to main run the deploy role.
  plan_subjects = [
    "repo:${local.repo}:pull_request",
  ]
  deploy_subjects = [
    "repo:${local.repo}:ref:refs/heads/main",
    "repo:${local.repo}:environment:production",
  ]
}

data "aws_caller_identity" "current" {}

#############################################
# Terraform remote state: S3 bucket
#############################################

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name

  # State is precious; block accidental destroys.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Deny any request not made over TLS (i.e. plaintext HTTP).
data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  # Apply the public-access-block first so this Deny policy is not mistaken
  # for one that grants public access.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# State locking uses S3-native locking (`use_lockfile = true` in the backend),
# so no DynamoDB table is needed — the lock is a `<key>.tflock` object stored in
# the state bucket itself.

#############################################
# GitHub Actions OIDC provider
#############################################

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

#############################################
# CI IAM roles assumed via OIDC
#############################################

# Trust policy template: only this repo, only the GitHub OIDC provider, and a
# restricted set of `sub` claims (PR vs. main/production).
data "aws_iam_policy_document" "plan_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
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
      identifiers = [aws_iam_openid_connect_provider.github.arn]
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
  name               = "${var.project}-ci-plan"
  assume_role_policy = data.aws_iam_policy_document.plan_assume_role.json
  description        = "Read-only role assumed by PR pipelines to run terraform plan."
}

# AWS-managed broad read-only access keeps plan honest without granting writes.
resource "aws_iam_role_policy_attachment" "ci_plan_readonly" {
  role       = aws_iam_role.ci_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Plan also needs to read remote state + acquire the lock.
data "aws_iam_policy_document" "tfstate_access" {
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

resource "aws_iam_role_policy" "ci_plan_state" {
  name   = "tfstate-access"
  role   = aws_iam_role.ci_plan.id
  policy = data.aws_iam_policy_document.tfstate_access.json
}

# DEPLOY role (push to main / production env): can apply app infra.
resource "aws_iam_role" "ci_deploy" {
  name               = "${var.project}-ci-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_assume_role.json
  description        = "Role assumed on merge to main to apply infra and deploy the app."
}

resource "aws_iam_role_policy" "ci_deploy_state" {
  name   = "tfstate-access"
  role   = aws_iam_role.ci_deploy.id
  policy = data.aws_iam_policy_document.tfstate_access.json
}

# TODO: tighten to least privilege per service once the app infra stabilises.
# For now grant the broad scopes the deploy pipeline needs (S3 web bucket,
# CloudFront invalidation, ECR push, ECS deploy, plus IAM/logs for resource
# management). Replace these managed policies with scoped inline policies.
resource "aws_iam_role_policy_attachment" "ci_deploy_power" {
  role       = aws_iam_role.ci_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}
