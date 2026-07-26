# Observability (observability.tf, #42): SNS alert topic + CloudWatch alarms
# and dashboard. SNS topics and CloudWatch alarms are project-name-scoped;
# CloudWatch dashboard ARNs have no region segment
# (arn:aws:cloudwatch::<account>:dashboard/<name>), so that action is split
# into its own statement without the regional condition (#258).
data "aws_iam_policy_document" "ci_deploy_observability" {
  statement {
    sid    = "SnsProjectTopics"
    effect = "Allow"
    # Service-level wildcard on this project's topic ARNs (ADR-0027 第2層, #658).
    # Subscription ARNs are `<topic-arn>:<uuid>`, so the same prefix covers the
    # subscription-attribute calls #600 had to add one at a time.
    actions   = ["sns:*"]
    resources = ["arn:aws:sns:*:*:${var.project}-*"]

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
    sid    = "CloudWatchAlarms"
    effect = "Allow"
    # Service-level wildcard on this project's alarm ARNs (ADR-0027 第2層, #658).
    actions   = ["cloudwatch:*"]
    resources = ["arn:aws:cloudwatch:*:*:alarm:${var.project}-*"]

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
    sid    = "CloudWatchDashboard"
    effect = "Allow"
    # Service-level wildcard on this project's dashboard ARNs (ADR-0027 第2層, #658).
    # Still separate from CloudWatchAlarms: dashboard ARNs carry no region segment, which
    # is why this statement deliberately has no aws:RequestedRegion condition (#258). That
    # asymmetry is also why iam_wildcard.rego cannot require a region condition for every
    # wildcard action -- see the rule's comment.
    actions   = ["cloudwatch:*"]
    resources = ["arn:aws:cloudwatch::*:dashboard/${var.project}-*"]
  }
}
