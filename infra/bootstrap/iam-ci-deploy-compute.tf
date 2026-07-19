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

    dynamic "condition" {
      for_each = [local.region_condition]
      content {
        test     = condition.value.test
        variable = condition.value.variable
        values   = condition.value.values
      }
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

    dynamic "condition" {
      for_each = [local.region_condition]
      content {
        test     = condition.value.test
        variable = condition.value.variable
        values   = condition.value.values
      }
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

    dynamic "condition" {
      for_each = [local.region_condition]
      content {
        test     = condition.value.test
        variable = condition.value.variable
        values   = condition.value.values
      }
    }
  }
}

resource "aws_iam_policy" "ci_deploy_compute" {
  name   = "${local.name_prefix}-deploy-compute"
  policy = data.aws_iam_policy_document.ci_deploy_compute.json
}

resource "aws_iam_role_policy_attachment" "ci_deploy_compute" {
  role       = aws_iam_role.ci_deploy.name
  policy_arn = aws_iam_policy.ci_deploy_compute.arn
}
