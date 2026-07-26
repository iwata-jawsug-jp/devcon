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
    sid    = "RdsDescribe"
    effect = "Allow"
    actions = [
      "rds:DescribeDBInstances",
      "rds:DescribeDBSubnetGroups",
      "rds:ListTagsForResource",
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
    sid    = "RdsProjectResources"
    effect = "Allow"
    # Service-level wildcard on this project's db: ARNs (ADR-0027 第2層, #658).
    actions   = ["rds:*"]
    resources = ["arn:aws:rds:*:*:db:${var.project}-*"]

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
    sid    = "RdsSubnetGroup"
    effect = "Allow"
    # Service-level wildcard on this project's subgrp: ARNs (ADR-0027 第2層, #658).
    # Kept separate from RdsProjectResources because the *resource type* differs and that
    # is the axis still enforcing anything: rds:CreateDBInstance is evaluated against both
    # the db: it creates and the subgrp: it places the instance into, and default_tags
    # makes tagging hit both types too (#258). One statement per resource type keeps that
    # explicit.
    actions   = ["rds:*"]
    resources = ["arn:aws:rds:*:*:subgrp:${var.project}-*"]

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
    # logs:DescribeLogGroups doesn't support the log-group ARN pattern used
    # below -- AWS evaluates it against a `log-group::log-stream:` pseudo
    # resource instead, so it needs its own Resource "*" statement (#258).
    sid       = "LogsDescribe"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
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
    sid    = "LogsProjectGroup"
    effect = "Allow"
    # Service-level wildcard on this project's log-group ARNs (ADR-0027 第2層, #658).
    actions   = ["logs:*"]
    resources = ["arn:aws:logs:*:*:log-group:/${var.project}/*"]

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
