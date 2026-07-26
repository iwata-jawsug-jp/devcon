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
    # Service-level wildcard, deliberately (ADR-0027 第2層, #658): the resource ARN and
    # region axes below still do the work, and enumerating ECR actions bought nothing but
    # a sandbox round-trip every time the provider called one more of them. What the old
    # 21-action list encoded, kept because it is not obvious from the resource blocks:
    # the image push in cd-app.yml, and Set/GetRepositoryPolicy for worker.tf's
    # container-image Lambda (#640) -- CreateFunction with package_type=Image makes Lambda
    # auto-add its own pull grant to the repo, but only if the caller holds those two.
    sid       = "EcrProjectRepo"
    effect    = "Allow"
    actions   = ["ecr:*"]
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
    # `ecs:*` scoped to this project's cluster/service/task ARNs (ADR-0027 第2層, #658).
    # Note the ARNs below are the whole guardrail here: ECS actions that AWS does not
    # authorize against these resource types are unaffected by widening the action list --
    # they still need their own statements (EcsProjectTaskDefinitions,
    # EcsTaskDefinitionReadDeregister below).
    sid     = "EcsProjectResources"
    effect  = "Allow"
    actions = ["ecs:*"]
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
    #
    # Why this stays a separate statement now that both it and
    # EcsProjectResources say `ecs:*` (ADR-0027 第2層, #658): they differ in
    # the *resource*, and that is the axis still doing the work. AWS
    # authorizes RegisterTaskDefinition / RunTask / the TagResource call that
    # default_tags triggers at registration against the task-definition ARN
    # (for RunTask the cluster is a condition key, not a resource), so those
    # calls can only ever match here -- listing them in EcsProjectResources
    # would never match its cluster/service/task ARNs. Merging the two
    # statements would mean unioning the resource lists, which widens more
    # than the action axis ever did.
    sid       = "EcsProjectTaskDefinitions"
    effect    = "Allow"
    actions   = ["ecs:*"]
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
  # ECR pull-through cache rules (#3/#598) are registry-wide settings, not
  # per-repository resources -- like EcrAuth's GetAuthorizationToken above,
  # these actions have no resource-level ARN support and need Resource "*".
  statement {
    sid    = "EcrPullThroughCache"
    effect = "Allow"
    actions = [
      "ecr:CreatePullThroughCacheRule",
      "ecr:DeletePullThroughCacheRule",
      "ecr:DescribePullThroughCacheRules",
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
