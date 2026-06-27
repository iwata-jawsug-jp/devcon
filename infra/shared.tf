# Shared / foundational resources used by both web and api.

# Central CloudWatch log group for application + task logs.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project}/${var.environment}"
  retention_in_days = 30
}

# TODO: VPC + networking foundation.
#   - aws_vpc / subnets (public + private across 2 AZs)
#   - aws_internet_gateway, NAT (or VPC endpoints to avoid NAT cost)
#   - route tables + security groups
# Prefer the official `terraform-aws-modules/vpc/aws` module here.
#
# TODO: shared IAM roles for ECS (task execution role + task role) once api.tf
# grows an ECS service.
