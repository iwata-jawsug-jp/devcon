variable "project" {
  description = "Project name, used for tagging and resource naming."
  type        = string
  default     = "devcon"
}

variable "environment" {
  description = "Deployment environment (e.g. dev, stg, prod)."
  type        = string
  default     = "dev"

  validation {
    # "gp-verify", not "golden-path-verify": aws_lb/aws_lb_target_group names are
    # capped at 32 chars, and "${var.project}-golden-path-verify-api" exceeds that
    # (docs/proposal/template-verification-environment-proposal.md §3.2).
    condition     = contains(["dev", "stg", "prod", "sandbox", "gp-verify"], var.environment)
    error_message = "environment must be one of: dev, stg, prod, sandbox, gp-verify."
  }
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-northeast-1"
}

# Reserved for the ECS task definition (api.tf); set by the deploy pipeline. Not yet wired.
# tflint-ignore: terraform_unused_declarations
variable "container_image" {
  description = "Container image (repo:tag) for the api service. Set by the deploy pipeline."
  type        = string
  default     = ""
}

# Reserved for optional ACM/Route53 on the web SPA (web.tf TODO). Not yet wired.
# tflint-ignore: terraform_unused_declarations
variable "domain_name" {
  description = "Optional custom domain for the web SPA (e.g. app.example.com). Empty disables ACM/Route53."
  type        = string
  default     = ""
}

# --- Networking ---

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

# Each interface endpoint (endpoints.tf) normally spans both private subnets
# (2 AZ) -- 4 endpoints x 2 AZ = 8 ENIs, a fixed ~$80/month regardless of
# traffic (#153, #306). Dev/sandbox don't need the redundancy, so default to
# a single AZ there; prod opts into the full 2 AZ via its tfvars.
variable "vpce_single_az" {
  description = "Deploy interface VPC endpoints to a single AZ instead of all private subnets."
  type        = bool
  default     = true
}

# --- Database (RDS PostgreSQL) ---

variable "db_engine_version" {
  description = "PostgreSQL engine version (major version is sufficient)."
  type        = string
  default     = "16"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Initial allocated storage for the database, in GiB."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Upper bound for storage autoscaling, in GiB."
  type        = number
  default     = 100
}

variable "db_name" {
  description = "Name of the initial application database."
  type        = string
  default     = "app"
}

variable "db_username" {
  description = "Master username for the database."
  type        = string
  default     = "app"
}

variable "db_backup_retention" {
  description = "Number of days to retain automated backups."
  type        = number
  default     = 7
}

variable "db_multi_az" {
  description = "Whether to deploy the database across multiple AZs."
  type        = bool
  default     = false
}

variable "db_deletion_protection" {
  description = "Whether to enable deletion protection on the database."
  type        = bool
  default     = true
}

variable "db_skip_final_snapshot" {
  description = "Whether to skip the final snapshot when the database is destroyed."
  type        = bool
  default     = false
}

# --- ECS Application Auto Scaling (api.tf) ---

variable "ecs_min_capacity" {
  description = "Minimum number of running api tasks."
  type        = number
  default     = 1
}

variable "ecs_max_capacity" {
  description = "Maximum number of running api tasks Application Auto Scaling can create. Equal to ecs_min_capacity effectively disables scaling (dev default)."
  type        = number
  default     = 1
}

variable "ecs_cpu_target_value" {
  description = "Target average CPU utilization percentage for ECS task autoscaling."
  type        = number
  default     = 60
}

variable "ecs_memory_target_value" {
  description = "Target average memory utilization percentage for ECS task autoscaling."
  type        = number
  default     = 70
}

# --- Observability (observability.tf, #42) ---

variable "alert_email" {
  description = "Email address subscribed to the CloudWatch alarm SNS topic. Empty disables the subscription."
  type        = string
  default     = ""
}

variable "alarm_alb_5xx_threshold" {
  description = "ALB target 5xx count (per 5-minute period) above which the alarm fires."
  type        = number
  default     = 5
}

variable "alarm_alb_latency_seconds" {
  description = "ALB average target response time (seconds) above which the alarm fires."
  type        = number
  default     = 1
}

variable "alarm_ecs_cpu_threshold" {
  description = "ECS api service average CPU utilization percentage above which the alarm fires."
  type        = number
  default     = 80
}

variable "alarm_ecs_memory_threshold" {
  description = "ECS api service average memory utilization percentage above which the alarm fires."
  type        = number
  default     = 80
}

variable "alarm_rds_cpu_threshold" {
  description = "RDS average CPU utilization percentage above which the alarm fires."
  type        = number
  default     = 80
}

variable "alarm_rds_connections_threshold" {
  description = "RDS average connection count above which the alarm fires. Sized for the dev default (db.t4g.micro, ~110 max connections); lower prod headroom means raising this if the instance class grows."
  type        = number
  default     = 80
}

variable "alarm_rds_free_storage_bytes" {
  description = "RDS free storage space (bytes) below which the alarm fires."
  type        = number
  default     = 2000000000 # 2 GiB
}

# --- Distributed tracing (ADR-0007) ---

variable "otel_traces_enabled" {
  description = "Whether to schedule the ADOT collector sidecar + enable app tracing. Off by default (extra task cpu/memory, VPC endpoint, and IAM only apply when true)."
  type        = bool
  default     = false
}

variable "otel_collector_image" {
  description = "ADOT (AWS Distro for OpenTelemetry) collector image, only scheduled when otel_traces_enabled is true."
  type        = string
  default     = "public.ecr.aws/aws-observability/aws-otel-collector:v0.40.0"
}
