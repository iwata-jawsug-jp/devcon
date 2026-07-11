#!/usr/bin/env bash
# Used by api.tf's `data "external" "api_current_image"` (#374): report the
# image tag the api ECS service is actually running, so infra-only terraform
# applies (no new build) re-register a task-def revision with a real image
# instead of the nonexistent ":bootstrap" placeholder.
#
# Never fails the data source read: if the cluster/service doesn't exist yet
# (first-ever apply, or a `dev`-env plan against a never-applied state) or AWS
# auth isn't available, prints an empty image and lets the caller fall back.
set -euo pipefail

cluster="$1"
service="$2"
region="$3"

task_def_arn=$(aws ecs describe-services \
  --cluster "$cluster" --services "$service" --region "$region" \
  --query 'services[0].taskDefinition' --output text 2>/dev/null) || task_def_arn=""

if [ -z "$task_def_arn" ] || [ "$task_def_arn" = "None" ]; then
  printf '{"image": ""}\n'
  exit 0
fi

image=$(aws ecs describe-task-definition \
  --task-definition "$task_def_arn" --region "$region" \
  --query "taskDefinition.containerDefinitions[?name=='api'].image | [0]" \
  --output text 2>/dev/null) || image=""

if [ "$image" = "None" ]; then
  image=""
fi

printf '{"image": "%s"}\n' "$image"
