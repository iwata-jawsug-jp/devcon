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
    condition     = contains(["dev", "stg", "prod", "sandbox"], var.environment)
    error_message = "environment must be one of: dev, stg, prod, sandbox."
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
