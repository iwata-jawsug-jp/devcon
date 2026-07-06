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

# Interface endpoints for ECR (api + dkr), CloudWatch Logs, and Secrets Manager.
# `xray` is added only when tracing is enabled (ADR-0007) — the ADOT collector
# sidecar needs it to reach the X-Ray API with no NAT gateway in this VPC.
locals {
  interface_endpoints = merge(
    {
      ecr_api        = "ecr.api"
      ecr_dkr        = "ecr.dkr"
      logs           = "logs"
      secretsmanager = "secretsmanager"
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
