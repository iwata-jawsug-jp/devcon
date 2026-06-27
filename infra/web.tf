# Web (SPA) hosting: private S3 origin behind CloudFront.

# Private bucket that holds the built SPA (`dist/`). Never public; CloudFront
# reaches it via an Origin Access Control (see TODO below).
resource "aws_s3_bucket" "web" {
  bucket = "${local.name_prefix}-web"
}

resource "aws_s3_bucket_public_access_block" "web" {
  bucket = aws_s3_bucket.web.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "web" {
  bucket = aws_s3_bucket.web.id

  versioning_configuration {
    status = "Enabled"
  }
}

# TODO: CloudFront distribution fronting the SPA.
#   - aws_cloudfront_origin_access_control (OAC, sigv4) for the S3 origin
#   - aws_cloudfront_distribution: default behavior -> S3 (SPA), and an
#     `/api/*` behavior -> the api origin (ALB) per the CLAUDE.md architecture
#   - bucket policy granting s3:GetObject to the distribution via OAC
#   - SPA custom error responses (403/404 -> /index.html)
#
# TODO (optional, when var.domain_name != ""): ACM cert in us-east-1 + Route53
# alias record for the custom domain.
