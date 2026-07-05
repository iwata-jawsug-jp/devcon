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
  name               = "${var.project}-ci-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_assume_role.json
  description        = "Role assumed on merge to main to apply infra and deploy the app."
}

resource "aws_iam_role_policy" "ci_deploy_state" {
  name   = "tfstate-access"
  role   = aws_iam_role.ci_deploy.id
  policy = data.aws_iam_policy_document.tfstate_access_deploy.json
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

    # EC2 networking is entirely regional; nothing here legitimately targets a
    # region other than where this project's infra lives (#45).
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
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

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
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

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
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

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
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
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  # ELB has no resource-level ARN support for load balancer / target group /
  # listener creation (the ARN doesn't exist until after Create*), so this is
  # scoped by action instead of resource -- narrowed from `elasticloadbalancing:*`
  # to only the actions the ALB resources actually declared in api.tf need
  # (aws_lb, aws_lb_target_group, aws_lb_listener, aws_lb_listener_rule) (#45).
  statement {
    sid    = "Elb"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:SetSecurityGroups",
      "elasticloadbalancing:SetSubnets",
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeListenerAttributes",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:DeleteRule",
      "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
      "elasticloadbalancing:DescribeTags",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  # Application Auto Scaling has no resource-level ARN support either --
  # narrowed from `application-autoscaling:*` to only the actions the
  # ECS scalable-target/policy resources in api.tf need (#45).
  statement {
    sid    = "ApplicationAutoScaling"
    effect = "Allow"
    actions = [
      "application-autoscaling:RegisterScalableTarget",
      "application-autoscaling:DeregisterScalableTarget",
      "application-autoscaling:DescribeScalableTargets",
      "application-autoscaling:PutScalingPolicy",
      "application-autoscaling:DeleteScalingPolicy",
      "application-autoscaling:DescribeScalingPolicies",
      "application-autoscaling:DescribeScalingActivities",
      "application-autoscaling:TagResource",
      "application-autoscaling:UntagResource",
      "application-autoscaling:ListTagsForResource",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
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

    # No aws:RequestedRegion condition here: S3 bucket names are global and
    # some SDKs/CLI (incl. cd-app.yml's `aws s3 sync`) may route through the
    # global/us-east-1 endpoint even for a bucket created in ap-northeast-1,
    # so adding a region condition risks spurious AccessDenied (#45).
  }
  # CloudFront is a global service (no resource-level ARN support, no
  # meaningful aws:RequestedRegion), so this stays scoped by action only --
  # narrowed from `cloudfront:*` to what the OAC / response-headers-policy /
  # distribution resources in web.tf need, plus the `aws cloudfront
  # create-invalidation` call cd-app.yml / cd-app-sandbox.yml run directly (#45).
  statement {
    sid    = "CloudFront"
    effect = "Allow"
    actions = [
      "cloudfront:CreateOriginAccessControl",
      "cloudfront:GetOriginAccessControl",
      "cloudfront:UpdateOriginAccessControl",
      "cloudfront:DeleteOriginAccessControl",
      "cloudfront:ListOriginAccessControls",
      "cloudfront:CreateResponseHeadersPolicy",
      "cloudfront:GetResponseHeadersPolicy",
      "cloudfront:UpdateResponseHeadersPolicy",
      "cloudfront:DeleteResponseHeadersPolicy",
      "cloudfront:ListResponseHeadersPolicies",
      "cloudfront:CreateDistribution",
      "cloudfront:GetDistribution",
      "cloudfront:UpdateDistribution",
      "cloudfront:DeleteDistribution",
      "cloudfront:ListDistributions",
      "cloudfront:TagResource",
      "cloudfront:UntagResource",
      "cloudfront:ListTagsForResource",
      "cloudfront:CreateInvalidation",
      "cloudfront:GetInvalidation",
      "cloudfront:ListInvalidations",
    ]
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

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
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

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
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

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
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

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
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

resource "aws_iam_role_policy" "ci_deploy_iam" {
  name   = "manage-project-iam"
  role   = aws_iam_role.ci_deploy.id
  policy = data.aws_iam_policy_document.ci_deploy_iam.json
}
