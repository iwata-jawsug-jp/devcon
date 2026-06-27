# Minimal VPC networking foundation: 2 AZs, public + private subnets.
#
# Public subnets reach the internet via an internet gateway. Private subnets
# (where RDS and the future ECS tasks live) currently have no egress — RDS does
# not need it. NAT/VPC endpoints are added later when ECS needs outbound access.

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

# Public subnets (n = 0, 1) — for load balancers / NAT in a later PR.
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-public-${count.index}"
    Tier = "public"
  }
}

# Private subnets (n = 10, 11) — RDS and the future ECS tasks.
resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${local.name_prefix}-private-${count.index}"
    Tier = "private"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# Public route table: default route to the internet gateway.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-public"
  }
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route table: no default route yet (no egress).
# TODO: NAT gateway or VPC endpoints when ECS needs egress
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-private"
  }
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# App security group: attached by the future ECS/api tasks. No ingress yet
# (the ALB SG will be the only source later); egress is open so tasks can reach
# the DB and, once NAT/endpoints exist, the internet.
resource "aws_security_group" "app" {
  name_prefix = "${local.name_prefix}-app-"
  description = "App/ECS task security group"
  vpc_id      = aws_vpc.main.id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.name_prefix}-app"
  }
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "Allow all outbound traffic from app tasks"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# DB security group: PostgreSQL reachable only from the app SG.
resource "aws_security_group" "db" {
  name_prefix = "${local.name_prefix}-db-"
  description = "RDS PostgreSQL security group"
  vpc_id      = aws_vpc.main.id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.name_prefix}-db"
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from app security group"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "db_all" {
  security_group_id = aws_security_group.db.id
  description       = "Allow all outbound traffic from the database"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
