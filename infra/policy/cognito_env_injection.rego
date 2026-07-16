package main

# Backend: infra/api.tf's ECS task definition must inject API_COGNITO_* into the "api"
# container (#369 regression). container_definitions is a jsonencode()'d string that
# becomes wholly unknown at plan time whenever any input to it is unknown (e.g. a
# not-yet-created aws_db_instance) -- skip gracefully rather than false-failing, same
# precedent as check_iam_policies.py's "policy value not known until apply".
required_api_cognito_env_names := {"API_COGNITO_USER_POOL_ID", "API_COGNITO_REGION", "API_COGNITO_CLIENT_ID"}

deny contains msg if {
	rc := input.resource_changes[_]
	rc.type == "aws_ecs_task_definition"
	rc.change.after.container_definitions != null
	containers := json.unmarshal(rc.change.after.container_definitions)
	api_container := [c | c := containers[_]; c.name == "api"][0]
	env_names := {e.name | e := api_container.environment[_]}
	missing := required_api_cognito_env_names - env_names
	count(missing) > 0
	msg := sprintf("%s: ECS container \"api\" is missing required env var(s): %v", [rc.address, missing])
}

# Frontend: cd-app.yml / cd-app-sandbox.yml's "frontend" job's "Build" step must inject
# VITE_COGNITO_* (#367 regression). Input here is the workflow YAML itself, not a
# terraform plan -- conftest can take either, and this rule is a no-op (undefined guard)
# against any input that isn't shaped like one of these two workflow files.
required_vite_cognito_env_keys := {"VITE_COGNITO_USER_POOL_ID", "VITE_COGNITO_REGION", "VITE_COGNITO_CLIENT_ID", "VITE_COGNITO_DOMAIN"}

deny contains msg if {
	input.jobs.frontend
	build_step := [s | s := input.jobs.frontend.steps[_]; s.name == "Build"][0]
	env := object.get(build_step, "env", {})
	present := {k | env[k]}
	missing := required_vite_cognito_env_keys - present
	count(missing) > 0
	msg := sprintf("frontend job's Build step is missing required env var(s): %v", [missing])
}
