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
  name   = "${local.name_prefix}-deploy-storage-cdn"
  policy = data.aws_iam_policy_document.ci_deploy_storage_cdn.json
}

resource "aws_iam_role_policy_attachment" "ci_deploy_storage_cdn" {
  role       = aws_iam_role.ci_deploy.name
  policy_arn = aws_iam_policy.ci_deploy_storage_cdn.arn
}
