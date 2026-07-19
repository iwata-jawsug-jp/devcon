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
    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
      "cloudwatch:ListTagsForResource",
    ]
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
  name   = "${local.name_prefix}-deploy-observability"
  policy = data.aws_iam_policy_document.ci_deploy_observability.json
}

resource "aws_iam_role_policy_attachment" "ci_deploy_observability" {
  role       = aws_iam_role.ci_deploy.name
  policy_arn = aws_iam_policy.ci_deploy_observability.arn
}
