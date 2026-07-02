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
    # Sandbox dev environment: any sandbox/* branch may assume the deploy role so
    # cd-infra-sandbox can verify `terraform apply`. Isolated by the sandbox guard
    # (sandbox/* never merges into main). See docs/sandbox.md.
    "repo:${local.repo}:ref:refs/heads/sandbox/*",
  ]
}

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

# Least-privilege scoped policies (#45), replacing a prior PowerUserAccess
# attachment. Split by service group to stay under per-policy size limits and
# to keep each block reviewable. Resource ARNs are scoped to this project's
# naming (`${var.project}-*` / `/${var.project}/*`) everywhere AWS IAM
# supports resource-level restriction for the action; a handful of
# describe/list/create actions genuinely require Resource "*" because the
# service doesn't support resource-level permissions for them (called out
# per statement below). This was derived from the AWS resource types actually
# declared in infra/*.tf, not from CloudTrail access-history — validate with
# `terraform plan`/`apply` against a real environment before relying on it,
# and watch for AccessDenied errors on first use (see docs/infrastructure.md).

# Networking (network.tf, endpoints.tf): VPC, subnets, IGW, route tables,
# security groups + rules, VPC endpoints. EC2 doesn't support resource-level
# ARN restriction for most of these actions (its managed policies like
# AmazonVPCFullAccess use Resource "*" too), so this is scoped by action
# rather than resource — still far narrower than PowerUserAccess, which grants
# every EC2 action plus ~350 other services this project doesn't use.
data "aws_iam_policy_document" "ci_deploy_network" {
  statement {
    sid    = "Ec2Networking"
    effect = "Allow"
    actions = [
      "ec2:DescribeVpcs",
      "ec2:CreateVpc",
      "ec2:DeleteVpc",
      "ec2:ModifyVpcAttribute",
      "ec2:DescribeVpcAttribute",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeSubnets",
      "ec2:CreateSubnet",
      "ec2:DeleteSubnet",
      "ec2:ModifySubnetAttribute",
      "ec2:DescribeInternetGateways",
      "ec2:CreateInternetGateway",
      "ec2:DeleteInternetGateway",
      "ec2:AttachInternetGateway",
      "ec2:DetachInternetGateway",
      "ec2:DescribeRouteTables",
      "ec2:CreateRouteTable",
      "ec2:DeleteRouteTable",
      "ec2:CreateRoute",
      "ec2:DeleteRoute",
      "ec2:ReplaceRoute",
      "ec2:AssociateRouteTable",
      "ec2:DisassociateRouteTable",
      "ec2:ReplaceRouteTableAssociation",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSecurityGroupRules",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
      "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
      "ec2:DescribeVpcEndpoints",
      "ec2:CreateVpcEndpoint",
      "ec2:DeleteVpcEndpoints",
      "ec2:ModifyVpcEndpoint",
      "ec2:DescribeManagedPrefixLists",
      "ec2:GetManagedPrefixListEntries",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:DescribeTags",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ci_deploy_network" {
  name   = "deploy-network"
  role   = aws_iam_role.ci_deploy.id
  policy = data.aws_iam_policy_document.ci_deploy_network.json
}

# Compute (api.tf): ECS cluster/service/task-definition + autoscaling, ECR
# repository (incl. the image push cd-app.yml does), and the ALB in front of
# it. ECR repository actions and ECS cluster/service/task-definition-family
# actions are scoped by ARN/name; `ecr:GetAuthorizationToken` and most ELB +
# Application Auto Scaling actions require Resource "*" (no resource-level
# support in those APIs).
data "aws_iam_policy_document" "ci_deploy_compute" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid    = "EcrProjectRepo"
    effect = "Allow"
    actions = [
      "ecr:DescribeRepositories",
      "ecr:CreateRepository",
      "ecr:DeleteRepository",
      "ecr:PutLifecyclePolicy",
      "ecr:GetLifecyclePolicy",
      "ecr:DeleteLifecyclePolicy",
      "ecr:SetRepositoryPolicy",
      "ecr:GetRepositoryPolicy",
      "ecr:PutImageScanningConfiguration",
      "ecr:TagResource",
      "ecr:UntagResource",
      "ecr:ListTagsForResource",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = ["arn:aws:ecr:*:*:repository/${var.project}-*"]
  }
  statement {
    sid    = "EcsProjectResources"
    effect = "Allow"
    actions = [
      "ecs:DescribeClusters",
      "ecs:CreateCluster",
      "ecs:DeleteCluster",
      "ecs:UpdateClusterSettings",
      "ecs:DescribeServices",
      "ecs:CreateService",
      "ecs:UpdateService",
      "ecs:DeleteService",
      "ecs:DescribeTasks",
      "ecs:RunTask",
      "ecs:StopTask",
      "ecs:TagResource",
      "ecs:UntagResource",
      "ecs:ListTagsForResource",
    ]
    resources = [
      "arn:aws:ecs:*:*:cluster/${var.project}-*",
      "arn:aws:ecs:*:*:service/${var.project}-*/*",
      "arn:aws:ecs:*:*:task/${var.project}-*/*",
    ]
  }
  statement {
    # Task-definition family actions don't support resource-level ARN scoping
    # for Register/Deregister (only the resulting revision ARN exists after
    # the call); the ecs:task-definition-family condition key restricts which
    # family names the caller may register/describe against instead.
    sid    = "EcsTaskDefinitions"
    effect = "Allow"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:DeregisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
      "ecs:ListTaskDefinitions",
    ]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "ecs:task-definition-family"
      values   = ["${var.project}-*"]
    }
  }
  statement {
    sid       = "Elb"
    effect    = "Allow"
    actions   = ["elasticloadbalancing:*"]
    resources = ["*"]
  }
  statement {
    sid       = "ApplicationAutoScaling"
    effect    = "Allow"
    actions   = ["application-autoscaling:*"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ci_deploy_compute" {
  name   = "deploy-compute"
  role   = aws_iam_role.ci_deploy.id
  policy = data.aws_iam_policy_document.ci_deploy_compute.json
}

# Storage + CDN (web.tf): the SPA's S3 bucket + CloudFront distribution.
# S3 is scoped to this project's bucket names; CloudFront has no
# resource-level ARN support for most management actions.
data "aws_iam_policy_document" "ci_deploy_storage_cdn" {
  statement {
    sid    = "S3ProjectBuckets"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:GetBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:GetBucketVersioning",
      "s3:PutBucketVersioning",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketTagging",
      "s3:PutBucketTagging",
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:aws:s3:::${var.project}-*",
      "arn:aws:s3:::${var.project}-*/*",
    ]
  }
  statement {
    sid       = "CloudFront"
    effect    = "Allow"
    actions   = ["cloudfront:*"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ci_deploy_storage_cdn" {
  name   = "deploy-storage-cdn"
  role   = aws_iam_role.ci_deploy.id
  policy = data.aws_iam_policy_document.ci_deploy_storage_cdn.json
}

# Data + logs (db.tf, shared.tf): RDS instance/subnet group and the
# CloudWatch log group. RDS Describe*/List* actions require Resource "*";
# the mutating actions are scoped to this project's DB identifier/subnet
# group name.
data "aws_iam_policy_document" "ci_deploy_data" {
  statement {
    sid    = "RdsDescribe"
    effect = "Allow"
    actions = [
      "rds:DescribeDBInstances",
      "rds:DescribeDBSubnetGroups",
      "rds:ListTagsForResource",
    ]
    resources = ["*"]
  }
  statement {
    sid    = "RdsProjectResources"
    effect = "Allow"
    actions = [
      "rds:CreateDBInstance",
      "rds:ModifyDBInstance",
      "rds:DeleteDBInstance",
      "rds:AddTagsToResource",
      "rds:RemoveTagsFromResource",
    ]
    resources = ["arn:aws:rds:*:*:db:${var.project}-*"]
  }
  statement {
    sid    = "RdsSubnetGroup"
    effect = "Allow"
    actions = [
      "rds:CreateDBSubnetGroup",
      "rds:ModifyDBSubnetGroup",
      "rds:DeleteDBSubnetGroup",
    ]
    resources = ["arn:aws:rds:*:*:subgrp:${var.project}-*"]
  }
  statement {
    sid    = "LogsProjectGroup"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DescribeLogGroups",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:ListTagsForResource",
    ]
    resources = ["arn:aws:logs:*:*:log-group:/${var.project}/*"]
  }
}

resource "aws_iam_role_policy" "ci_deploy_data" {
  name   = "deploy-data"
  role   = aws_iam_role.ci_deploy.id
  policy = data.aws_iam_policy_document.ci_deploy_data.json
}

# PowerUserAccess excludes IAM writes, but the app infra creates/manages its own
# IAM roles (ECS task execution/task roles) and must pass them to ECS. Grant
# IAM role management scoped to this project's role names + PassRole + the ECS/ELB
# service-linked roles.
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
      "iam:PassRole",
    ]
    resources = ["arn:aws:iam::*:role/${var.project}-*"]
  }
  statement {
    sid       = "ServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ci_deploy_iam" {
  name   = "manage-project-iam"
  role   = aws_iam_role.ci_deploy.id
  policy = data.aws_iam_policy_document.ci_deploy_iam.json
}
