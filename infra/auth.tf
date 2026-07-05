# Authn/authz (Issue #41): Cognito User Pool + Hosted UI for the SPA, and a
# custom resource server exposing read/write scopes the API authorizes against.
#
# Scope: infra provisioning only. JWT verification lives in the API
# (services/backend/python/src/api/auth/), and the Hosted UI login/callback
# flow lives in the frontend (services/frontend/src/auth/). See
# .kiro/specs/authn-authz/design.md (Components and Interfaces > Infra >
# CognitoInfra) for the full picture.
#
# No custom domain/ACM cert exists yet, so callback/logout URLs point at the
# existing CloudFront distribution (web.tf). Revisit when a custom domain
# lands (design.md Revalidation Triggers).

locals {
  # Base URL of the SPA as served today (no custom domain — see web.tf).
  app_base_url = "https://${aws_cloudfront_distribution.web.domain_name}"

  # Must match the frontend's login/callback routes (services/frontend/src/router,
  # tasks 1.2/1.3 of this spec: LoginView.vue / AuthCallbackView.vue).
  cognito_callback_urls = ["${local.app_base_url}/callback"]
  cognito_logout_urls   = ["${local.app_base_url}/login"]
}

# User directory. Essentials tier (Cognito's default — `user_pool_tier` is
# intentionally left unset here; do not add Plus-tier advanced security).
resource "aws_cognito_user_pool" "users" {
  name = "${local.name_prefix}-users"

  # Users sign in with their email address; Cognito verifies it via a code.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
}

# Custom resource server: defines the read/write scopes the API authorizes
# against (Requirement 2). Scopes are exposed as "<identifier>/<scope_name>",
# i.e. "api/items.read" and "api/items.write".
resource "aws_cognito_resource_server" "api" {
  identifier   = "api"
  name         = "api"
  user_pool_id = aws_cognito_user_pool.users.id

  scope {
    scope_name        = "items.read"
    scope_description = "Read access to items"
  }

  scope {
    scope_name        = "items.write"
    scope_description = "Write access to items"
  }
}

# Public client (no secret — Authorization Code + PKCE only, per design.md's
# rejection of ALB-level Cognito auth and its "public client" decision).
resource "aws_cognito_user_pool_client" "web" {
  name         = "${local.name_prefix}-web-client"
  user_pool_id = aws_cognito_user_pool.users.id

  generate_secret = false

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes = [
    "openid",
    "email",
    "${aws_cognito_resource_server.api.identifier}/items.read",
    "${aws_cognito_resource_server.api.identifier}/items.write",
  ]

  callback_urls                = local.cognito_callback_urls
  logout_urls                  = local.cognito_logout_urls
  supported_identity_providers = ["COGNITO"]

  # Only the OAuth/Hosted UI code flow is allowed; no direct
  # USER_PASSWORD_AUTH grant from this client.
  prevent_user_existence_errors = "ENABLED"
}

# Hosted UI domain. Cognito-prefix domain (no ACM cert / custom domain needed).
resource "aws_cognito_user_pool_domain" "hosted_ui" {
  domain       = "${local.name_prefix}-auth"
  user_pool_id = aws_cognito_user_pool.users.id
}
