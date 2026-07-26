# Messaging (worker.tf, #639/#640): the worker Lambda + its SQS trigger. Lambda function
# actions and SQS queue actions are scoped by ARN like EcrProjectRepo/EcsProjectResources
# (iam-ci-deploy-compute.tf). Event source mapping actions have no ARN known at policy-write
# time (the mapping UUID doesn't exist until CreateEventSourceMapping runs) -- same reasoning
# as the Elb statement there -- so those need Resource "*".
data "aws_iam_policy_document" "ci_deploy_messaging" {
  statement {
    sid    = "LambdaProjectFunction"
    effect = "Allow"
    # Service-level wildcard on this project's function ARNs (ADR-0027 第2層, #658).
    # #640 found lambda:ListVersionsByFunction the hard way -- the provider reads it after
    # Create/Update to populate qualified_arn/version, which no reading of the
    # aws_lambda_function schema would predict. That whole class is what the wildcard
    # removes; the ARN and region axes are untouched.
    actions   = ["lambda:*"]
    resources = ["arn:aws:lambda:*:*:function:${var.project}-*"]

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
    sid    = "LambdaEventSourceMappings"
    effect = "Allow"
    actions = [
      "lambda:CreateEventSourceMapping",
      "lambda:UpdateEventSourceMapping",
      "lambda:DeleteEventSourceMapping",
      "lambda:GetEventSourceMapping",
      "lambda:ListEventSourceMappings",
      # The event source mapping gets default_tags applied like any other taggable
      # resource, so the provider reads/writes its tags too -- refresh (incl. destroy)
      # calls ListTags unconditionally, not just when tags actually change
      # (CloudTrail-evidenced AccessDenied blocking `terraform destroy` in sandbox,
      # #640; same "provider tags whatever it can" pattern as
      # EcsProjectTaskDefinitions's TagResource, iam-ci-deploy-compute.tf).
      "lambda:ListTags",
      "lambda:TagResource",
      "lambda:UntagResource",
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
  statement {
    sid    = "SqsProjectQueue"
    effect = "Allow"
    # Service-level wildcard on this project's queue ARNs (ADR-0027 第2層, #658).
    actions   = ["sqs:*"]
    resources = ["arn:aws:sqs:*:*:${var.project}-*"]

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
