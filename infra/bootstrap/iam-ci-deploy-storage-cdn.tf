# aws_s3_bucket_server_side_encryption_configuration.web (web.tf) defaults to
# this AWS-managed key with no kms_master_key_id set, so ci_deploy needs
# explicit IAM permission on it too -- the key's own policy trusting the
# account is not sufficient, same two-sided-permission gap as the RDS/
# Secrets Manager default keys in iam-ci-deploy-data.tf (#587).
data "aws_kms_alias" "s3" {
  name = "alias/aws/s3"
}

# Storage + CDN (web.tf): the SPA's S3 bucket + CloudFront distribution.
# S3 is scoped to this project's bucket names; CloudFront has no
# resource-level ARN support for most management actions.
data "aws_iam_policy_document" "ci_deploy_storage_cdn" {
  statement {
    sid    = "S3ProjectBuckets"
    effect = "Allow"
    # Service-level wildcard on this project's bucket ARNs (ADR-0027 第2層, #658). This is
    # the statement #258 grew one AccessDenied at a time (Acl -> CORS -> Website, three
    # sandbox cycles, plus a batch of read-only sub-config getters added pre-emptively
    # afterwards) and #587 extended again for encryption config -- exactly the churn the
    # wildcard removes. No aws:RequestedRegion condition here, by the same #45 reasoning as
    # before: `aws s3 sync` may route through the global/us-east-1 endpoint for a bucket in
    # ap-northeast-1, so a region condition risks spurious AccessDenied.
    actions = ["s3:*"]
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
  # cd-app.yml's `aws s3 sync dist/ s3://.../` (PutObject) against the
  # SSE-KMS-by-default web bucket needs kms:GenerateDataKey on this key;
  # kms:DescribeKey covers Terraform's own read of the key during apply.
  # Starting point pending sandbox apply + CloudTrail confirmation, same as
  # RdsDefaultKmsKeyDescribe's history (#334) -- trim/extend once verified (#587).
  statement {
    sid       = "S3DefaultKmsKey"
    effect    = "Allow"
    actions   = ["kms:DescribeKey", "kms:GenerateDataKey"]
    resources = [data.aws_kms_alias.s3.target_key_arn]
  }
}
