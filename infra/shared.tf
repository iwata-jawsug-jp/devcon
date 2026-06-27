# Shared / foundational resources used by both web and api.

# Central CloudWatch log group for application + task logs.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project}/${var.environment}"
  retention_in_days = 30
}

# VPC + networking foundation lives in network.tf.
#
# TODO: shared IAM roles for ECS (task execution role + task role) once api.tf
# grows an ECS service.
