package main

test_deny_backend_missing_cognito_env if {
	container := {"name": "api", "environment": [{"name": "API_DB_HOST", "value": "x"}]}
	cd_json := json.marshal([container])
	rc := {
		"address": "aws_ecs_task_definition.api",
		"type": "aws_ecs_task_definition",
		"change": {"after": {"container_definitions": cd_json}},
	}
	violations := deny with input as {"resource_changes": [rc]}
	count(violations) == 1
}

test_allow_backend_with_cognito_env if {
	container := {"name": "api", "environment": [
		{"name": "API_DB_HOST", "value": "x"},
		{"name": "API_COGNITO_USER_POOL_ID", "value": "x"},
		{"name": "API_COGNITO_REGION", "value": "x"},
		{"name": "API_COGNITO_CLIENT_ID", "value": "x"},
	]}
	cd_json := json.marshal([container])
	rc := {
		"address": "aws_ecs_task_definition.api",
		"type": "aws_ecs_task_definition",
		"change": {"after": {"container_definitions": cd_json}},
	}
	violations := deny with input as {"resource_changes": [rc]}
	count(violations) == 0
}

test_allow_backend_unknown_at_plan_time_skipped if {
	rc := {
		"address": "aws_ecs_task_definition.api",
		"type": "aws_ecs_task_definition",
		"change": {"after": {"container_definitions": null}},
	}
	violations := deny with input as {"resource_changes": [rc]}
	count(violations) == 0
}

test_deny_frontend_missing_vite_env if {
	build_step := {"name": "Build", "env": {"VITE_COGNITO_USER_POOL_ID": "x"}}
	frontend_job := {"steps": [build_step]}
	violations := deny with input as {"jobs": {"frontend": frontend_job}}
	count(violations) == 1
}

test_allow_frontend_with_all_vite_env if {
	build_step := {"name": "Build", "env": {
		"VITE_COGNITO_USER_POOL_ID": "x",
		"VITE_COGNITO_REGION": "x",
		"VITE_COGNITO_CLIENT_ID": "x",
		"VITE_COGNITO_DOMAIN": "x",
	}}
	frontend_job := {"steps": [build_step]}
	violations := deny with input as {"jobs": {"frontend": frontend_job}}
	count(violations) == 0
}

test_allow_workflow_without_frontend_job_ignored if {
	violations := deny with input as {"jobs": {"plan": {"steps": []}}}
	count(violations) == 0
}

test_allow_terraform_plan_input_ignored_by_frontend_rule if {
	# package main is shared across infra/policy/*.rego -- use a fixture that can't trip
	# any other file's rule (no tags_all, no IAM policy, no route table/vpc endpoint).
	violations := deny with input as {"resource_changes": [{"address": "x", "type": "aws_cloudfront_function", "change": {"after": {"name": "x"}}}]}
	count(violations) == 0
}
