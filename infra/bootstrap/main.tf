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

# Versioned state objects otherwise keep every noncurrent version forever
# (#303). Current (live) state is never touched by this rule.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
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

resource "aws_iam_policy" "ci_deploy_state" {
  name   = "${var.project}-deploy-tfstate-access"
  policy = data.aws_iam_policy_document.tfstate_access_deploy.json
}

resource "aws_iam_role_policy_attachment" "ci_deploy_state" {
  role       = aws_iam_role.ci_deploy.name
  policy_arn = aws_iam_policy.ci_deploy_state.arn
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
      # Required by ELBv2's CreateLoadBalancer call (aws_lb.api, api.tf) --
      # missing this caused AccessDenied on the first-ever ALB creation in a
      # fresh environment (#437, devcon-test#15).
      "ec2:GetSecurityGroupsForVpc",
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
      # Read-only prefix-list lookup the AWS provider does while "flattening" a
      # VPC endpoint (both gateway and interface) -- distinct from the
      # DescribeManagedPrefixLists/GetManagedPrefixListEntries pair above.
      # Missing this caused every aws_vpc_endpoint apply to fail (#258).
      "ec2:DescribePrefixLists",
      # Also part of interface-endpoint "flattening": reading the ENIs the
      # endpoint attached, to populate its subnet/network-interface
      # attributes on every plan/apply refresh, not just first create (#258).
      "ec2:DescribeNetworkInterfaces",
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

resource "aws_iam_policy" "ci_deploy_network" {
  name   = "${var.project}-deploy-network"
  policy = data.aws_iam_policy_document.ci_deploy_network.json
}

resource "aws_iam_role_policy_attachment" "ci_deploy_network" {
  role       = aws_iam_role.ci_deploy.name
  policy_arn = aws_iam_policy.ci_deploy_network.arn
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
    # Actions that IAM evaluates against the task-definition ARN. This
    # statement previously used a nonexistent condition key
    # (ecs:task-definition-family) with Resource "*"; a condition on a key
    # that is never present in the request context can't match, so the whole
    # Allow was inert and RegisterTaskDefinition was denied in the sandbox
    # run (#338). RegisterTaskDefinition does support resource-level scoping
    # (evaluated against the family's task-definition/<family>:* ARN), so
    # scope by ARN instead.
    # - TagResource: default_tags applies tags at creation, so
    #   RegisterTaskDefinition also evaluates ecs:TagResource against the
    #   task-definition ARN (CloudTrail-evidenced denial in #338; same
    #   pattern as rds:AddTagsToResource on subgrp in #258). Untag/ListTags
    #   are deliberately absent: the provider reads task-definition tags via
    #   DescribeTaskDefinition(include=TAGS), and no run has exercised either.
    # - RunTask: authorized against the task-definition ARN per the service
    #   authorization reference (cluster is a condition key, not a resource),
    #   so it lives here, not in EcsProjectResources -- there it could never
    #   match. cd-app(-sandbox).yml's migrate job calls run-task under this
    #   role (PR #339 review).
    sid    = "EcsProjectTaskDefinitions"
    effect = "Allow"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:TagResource",
      "ecs:RunTask",
    ]
    resources = ["arn:aws:ecs:*:*:task-definition/${var.project}-*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  statement {
    # Deregister/DescribeTaskDefinition support no resource types in the ECS
    # service authorization reference, so they need their own Resource "*"
    # statement (same pattern as RdsDescribe/LogsDescribe). The previous
    # statement's ecs:ListTaskDefinitions was dropped: the AWS provider reads
    # task definitions via Describe only, and no run has exercised List (#338).
    sid    = "EcsTaskDefinitionReadDeregister"
    effect = "Allow"
    actions = [
      "ecs:DeregisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
    ]
    resources = ["*"]

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

resource "aws_iam_policy" "ci_deploy_compute" {
  name   = "${var.project}-deploy-compute"
  policy = data.aws_iam_policy_document.ci_deploy_compute.json
}

resource "aws_iam_role_policy_attachment" "ci_deploy_compute" {
  role       = aws_iam_role.ci_deploy.name
  policy_arn = aws_iam_policy.ci_deploy_compute.arn
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
      # The AWS provider's aws_s3_bucket resource reads a long list of
      # per-bucket sub-configurations on every refresh, even for ones this
      # project never sets explicitly -- discovered one at a time
      # (Acl, then CORS, then Website) across three sandbox apply
      # cycles (#258), so the remaining common ones are granted proactively
      # here rather than one AccessDenied at a time. All read-only and
      # already scoped to this project's bucket names below.
      "s3:GetBucketAcl",
      "s3:GetBucketCORS",
      "s3:GetBucketWebsite",
      "s3:GetBucketLogging",
      "s3:GetBucketRequestPayment",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:GetBucketOwnershipControls",
      # aws_s3_bucket_lifecycle_configuration.web (#303).
      "s3:GetLifecycleConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:GetBucketTagging",
      "s3:PutBucketTagging",
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      # aws_s3_bucket.web's force_destroy (golden-path-verify teardown):
      # the provider's force_destroy always calls ListObjectVersions to
      # empty the bucket before deleting it, even when versioning is off.
      "s3:ListBucketVersions",
      "s3:DeleteObjectVersion",
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
      # aws_cloudfront_function.spa_routing (web.tf, #439).
      "cloudfront:CreateFunction",
      "cloudfront:DescribeFunction",
      "cloudfront:GetFunction",
      "cloudfront:UpdateFunction",
      "cloudfront:DeleteFunction",
      "cloudfront:PublishFunction",
      "cloudfront:ListFunctions",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ci_deploy_storage_cdn" {
  name   = "${var.project}-deploy-storage-cdn"
  policy = data.aws_iam_policy_document.ci_deploy_storage_cdn.json
}

resource "aws_iam_role_policy_attachment" "ci_deploy_storage_cdn" {
  role       = aws_iam_role.ci_deploy.name
  policy_arn = aws_iam_policy.ci_deploy_storage_cdn.arn
}

# db.tf sets storage_encrypted = true without a kms_key_id, so RDS encrypts
# with the account's default AWS-managed key (alias/aws/rds). Creating an
# encrypted instance makes RDS create a grant on that key on the caller's
# behalf, which needs kms:CreateGrant/DescribeKey -- without it, apply fails
# with KMSKeyNotAccessibleFault even though the key itself is never
# referenced in db.tf (#258).
data "aws_kms_alias" "rds" {
  name = "alias/aws/rds"
}

# db.tf also sets manage_master_user_password = true, so RDS stores the master
# credentials in Secrets Manager encrypted with that service's default
# AWS-managed key (alias/aws/secretsmanager). Only kms:DescribeKey is needed
# on this key (the secret encryption itself happens service-side); CloudTrail
# from the sandbox run showed exactly that call denied, still surfacing as
# KMSKeyNotAccessibleFault (#334).
data "aws_kms_alias" "secretsmanager" {
  name = "alias/aws/secretsmanager"
}

# Data + logs (db.tf, shared.tf): RDS instance/subnet group and the
# CloudWatch log group. RDS Describe*/List* actions require Resource "*";
# the mutating actions are scoped to this project's DB identifier/subnet
# group name.
data "aws_iam_policy_document" "ci_deploy_data" {
  statement {
    # Trimmed to the CloudTrail-evidenced minimum (#334 / PR #337 review):
    # DescribeKey is the only action RDS forwards for both default keys.
    sid     = "RdsDefaultKmsKeyDescribe"
    effect  = "Allow"
    actions = ["kms:DescribeKey"]
    resources = [
      data.aws_kms_alias.rds.target_key_arn,
      data.aws_kms_alias.secretsmanager.target_key_arn,
    ]
  }
  statement {
    # CreateGrant was only ever exercised on the rds key (via
    # rds.amazonaws.com, for storage encryption); the GrantIsForAWSResource
    # condition pins it to grants created through an AWS service, per the
    # documented pattern for CreateGrant in identity policies. It gets its
    # own statement because the condition key is absent from DescribeKey
    # requests and would make the Bool test fail for them.
    sid       = "RdsDefaultKmsKeyGrant"
    effect    = "Allow"
    actions   = ["kms:CreateGrant"]
    resources = [data.aws_kms_alias.rds.target_key_arn]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
  statement {
    # With manage_master_user_password = true, RDS creates and tags the
    # master-credentials secret on the caller's behalf during
    # CreateDBInstance; per the RDS/Secrets Manager integration docs the
    # caller needs CreateSecret/TagResource (kms:DescribeKey is covered
    # above). RDS-managed secrets are always named with the `rds!` prefix,
    # not the project prefix, so scope to that (#334).
    sid    = "RdsManagedMasterUserSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:TagResource",
    ]
    resources = ["arn:aws:secretsmanager:*:*:secret:rds!*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
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
      # default_tags applies tags at creation time, which needs tagging
      # permission on the subgrp: resource type too -- RdsProjectResources
      # above only covers the db: resource type (#258).
      "rds:AddTagsToResource",
      "rds:RemoveTagsFromResource",
      # rds:CreateDBInstance also gets evaluated against the subnet group it
      # places the instance into, not just the db: resource it creates
      # (RdsProjectResources above already covers the db: side) (#258).
      "rds:CreateDBInstance",
    ]
    resources = ["arn:aws:rds:*:*:subgrp:${var.project}-*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  statement {
    # logs:DescribeLogGroups doesn't support the log-group ARN pattern used
    # below -- AWS evaluates it against a `log-group::log-stream:` pseudo
    # resource instead, so it needs its own Resource "*" statement (#258).
    sid       = "LogsDescribe"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]

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

resource "aws_iam_policy" "ci_deploy_data" {
  name   = "${var.project}-deploy-data"
  policy = data.aws_iam_policy_document.ci_deploy_data.json
}

resource "aws_iam_role_policy_attachment" "ci_deploy_data" {
  role       = aws_iam_role.ci_deploy.name
  policy_arn = aws_iam_policy.ci_deploy_data.arn
}

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

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
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

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
}

resource "aws_iam_policy" "ci_deploy_auth" {
  name   = "${var.project}-deploy-auth"
  policy = data.aws_iam_policy_document.ci_deploy_auth.json
}

resource "aws_iam_role_policy_attachment" "ci_deploy_auth" {
  role       = aws_iam_role.ci_deploy.name
  policy_arn = aws_iam_policy.ci_deploy_auth.arn
}

# Observability (observability.tf, #42): SNS alert topic + CloudWatch alarms
# and dashboard. SNS topics and CloudWatch alarms are project-name-scoped;
# CloudWatch dashboard ARNs have no region segment
# (arn:aws:cloudwatch::<account>:dashboard/<name>), so that action is split
# into its own statement without the regional condition (#258).
data "aws_iam_policy_document" "ci_deploy_observability" {
  statement {
    sid    = "SnsProjectTopics"
    effect = "Allow"
    actions = [
      "sns:CreateTopic",
      "sns:DeleteTopic",
      "sns:GetTopicAttributes",
      "sns:SetTopicAttributes",
      "sns:Subscribe",
      "sns:Unsubscribe",
      "sns:ListSubscriptionsByTopic",
      "sns:TagResource",
      "sns:UntagResource",
      "sns:ListTagsForResource",
    ]
    resources = ["arn:aws:sns:*:*:${var.project}-*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  statement {
    sid    = "CloudWatchAlarms"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
      "cloudwatch:ListTagsForResource",
    ]
    resources = ["arn:aws:cloudwatch:*:*:alarm:${var.project}-*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  statement {
    sid    = "CloudWatchDashboard"
    effect = "Allow"
    actions = [
      "cloudwatch:PutDashboard",
      "cloudwatch:GetDashboard",
      "cloudwatch:DeleteDashboards",
      "cloudwatch:ListDashboards",
    ]
    resources = ["arn:aws:cloudwatch::*:dashboard/${var.project}-*"]
  }
}

resource "aws_iam_policy" "ci_deploy_observability" {
  name   = "${var.project}-deploy-observability"
  policy = data.aws_iam_policy_document.ci_deploy_observability.json
}

resource "aws_iam_role_policy_attachment" "ci_deploy_observability" {
  role       = aws_iam_role.ci_deploy.name
  policy_arn = aws_iam_policy.ci_deploy_observability.arn
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
  name   = "${var.project}-manage-project-iam"
  policy = data.aws_iam_policy_document.ci_deploy_iam.json
}

resource "aws_iam_role_policy_attachment" "ci_deploy_iam" {
  role       = aws_iam_role.ci_deploy.name
  policy_arn = aws_iam_policy.ci_deploy_iam.arn
}
