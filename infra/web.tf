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

# CloudFront in front of the SPA (S3 via OAC) with an `/api/*` behavior to the ALB.

resource "aws_cloudfront_origin_access_control" "web" {
  name                              = "${local.name_prefix}-web-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# AWS-managed cache / origin-request policies (well-known IDs).
locals {
  cf_cache_optimized      = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
  cf_cache_disabled       = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
  cf_orp_all_viewer_nohdr = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader
}

# Security headers for the SPA (HTML/JS/CSS) responses from the S3 origin. Not attached to
# the /api/* behavior: that origin returns JSON, not browser-rendered HTML, and gets its own
# headers if/when the API adds them. The CSP has no 'unsafe-inline'/nonce because the Vite
# production build (`dist/index.html`) has no inline <script>/<style> — verified against the
# actual build output. If a future dependency injects inline styles/scripts, this policy will
# need a nonce or hash added alongside it, not just a blanket 'unsafe-inline'.
resource "aws_cloudfront_response_headers_policy" "web_security_headers" {
  name = "${local.name_prefix}-web-security-headers"

  security_headers_config {
    content_security_policy {
      override = true
      content_security_policy = join("; ", [
        "default-src 'self'",
        "script-src 'self'",
        "style-src 'self'",
        "img-src 'self' data:",
        "font-src 'self'",
        "connect-src 'self'",
        "object-src 'none'",
        "base-uri 'none'",
        "frame-ancestors 'none'",
        "form-action 'self'",
        "upgrade-insecure-requests",
      ])
    }

    content_type_options {
      override = true
    }

    frame_options {
      override     = true
      frame_option = "DENY"
    }

    referrer_policy {
      override        = true
      referrer_policy = "strict-origin-when-cross-origin"
    }

    strict_transport_security {
      override                   = true
      access_control_max_age_sec = 63072000 # 2 years
      include_subdomains         = true
      preload                    = true
    }
  }
}

resource "aws_cloudfront_distribution" "web" {
  enabled             = true
  default_root_object = "index.html"
  comment             = "${local.name_prefix} SPA + /api"

  origin {
    origin_id                = "s3-web"
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }

  origin {
    origin_id   = "alb-api"
    domain_name = aws_lb.api.dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Proves to the ALB (see aws_lb_listener_rule.api_from_cloudfront, api.tf) that a
    # request actually came through this distribution, not a third party's CloudFront
    # pointed at the same public ALB DNS name (#153, #271).
    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.cf_origin_verify.result
    }
  }

  default_cache_behavior {
    target_origin_id           = "s3-web"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = local.cf_cache_optimized
    response_headers_policy_id = aws_cloudfront_response_headers_policy.web_security_headers.id
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "alb-api"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = local.cf_cache_disabled
    origin_request_policy_id = local.cf_orp_all_viewer_nohdr
  }

  # SPA: serve index.html for client-side routes / missing keys.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  price_class = "PriceClass_200"
}

# Bucket policy: only this CloudFront distribution may read objects (via OAC).
data "aws_iam_policy_document" "web_oac" {
  statement {
    sid       = "AllowCloudFrontOAC"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.web.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.web.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "web" {
  bucket = aws_s3_bucket.web.id
  policy = data.aws_iam_policy_document.web_oac.json
}

# TODO (optional, when var.domain_name != ""): ACM cert in us-east-1 + Route53
# alias record for the custom domain.
