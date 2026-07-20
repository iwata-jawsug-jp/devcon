# VPC endpoints so Fargate tasks in the private subnets (no NAT) can pull images
# from ECR, ship logs, and read the RDS-managed secret — all over private links.

# SG for the interface endpoints: allow HTTPS from the app/task SG.
resource "aws_security_group" "endpoints" {
  name_prefix = "${local.name_prefix}-vpce-"
  description = "VPC interface endpoints (HTTPS from app tasks)"
  vpc_id      = aws_vpc.main.id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.name_prefix}-vpce"
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https_from_app" {
  security_group_id            = aws_security_group.endpoints.id
  description                  = "HTTPS from app tasks"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "endpoints_all" {
  security_group_id = aws_security_group.endpoints.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# S3 gateway endpoint (ECR image layers live in S3). Attached to the private RT.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${local.name_prefix}-s3"
  }
}

# Interface endpoints for ECR (api + dkr), CloudWatch Logs, Secrets Manager,
# and Cognito IDP. `xray` is added only when tracing is enabled (ADR-0007) —
# the ADOT collector sidecar needs it to reach the X-Ray API with no NAT
# gateway in this VPC.
#
# cognito_idp: the backend's JwksVerifier (api/auth/jwks.py) fetches signing
# keys from `https://cognito-idp.{region}.amazonaws.com/{pool_id}/.well-known
# /jwks.json` on every JWT it can't already verify from its in-memory cache.
# Without this endpoint, that's a public-internet hostname with no route
# from the private subnets (no NAT gateway here) -- the request just hangs
# until some far-off socket timeout, so every authenticated request stalls
# and eventually 504s. `private_dns_enabled = true` (below) makes that same
# public hostname resolve to this endpoint's private IP instead, so no code
# change is needed (issue #369).
locals {
  interface_endpoints = merge(
    {
      ecr_api        = "ecr.api"
      ecr_dkr        = "ecr.dkr"
      logs           = "logs"
      secretsmanager = "secretsmanager"
      cognito_idp    = "cognito-idp"
    },
    var.otel_traces_enabled ? { xray = "xray" } : {}
  )
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type = "Interface"
  # var.vpce_single_az (dev/sandbox default): 1 ENI per endpoint instead of 2,
  # halving the fixed monthly cost. prod opts into both AZs via its tfvars.
  subnet_ids          = var.vpce_single_az ? [aws_subnet.private[0].id] : aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${local.name_prefix}-${each.key}"
  }
}

# ECR pull-through cache for the ADOT collector image (#3): the collector's
# upstream image lives on Amazon ECR Public (public.ecr.aws, CloudFront-
# fronted), which is outside the ecr_api/ecr_dkr interface endpoints above --
# those only cover *this account's* private ECR API. Without NAT, a task
# referencing public.ecr.aws directly can't resolve/reach it and fails to
# provision (CannotPullContainerError). A pull-through cache rule makes ECR
# itself fetch and cache the upstream image on first pull, so the task can
# pull it through the same private ecr.dkr endpoint instead -- no NAT needed.
# api.tf's local.otel_collector_image rewrites var.otel_collector_image to
# this mirror's address before it reaches the container definition.
locals {
  ecr_public_pull_through_prefix = "ecr-public"
}

resource "aws_ecr_pull_through_cache_rule" "ecr_public" {
  count                 = var.otel_traces_enabled ? 1 : 0
  ecr_repository_prefix = local.ecr_public_pull_through_prefix
  upstream_registry_url = "public.ecr.aws"
}
