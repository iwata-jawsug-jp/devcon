# Allowlist AWS-managed policy attachments (#666).
#
# THE HOLE THIS CLOSES
#
# Every other IAM rule here (iam_wildcard.rego, region_condition.rego) inspects policy
# *documents* -- `aws_iam_policy` / `aws_iam_role_policy` / `aws_iam_user_policy`. Attaching
# an AWS-managed policy is a different resource with no document of its own, so
#
#     resource "aws_iam_role_policy_attachment" "oops" {
#       role       = aws_iam_role.ci_deploy.name
#       policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
#     }
#
# used to pass every blocking gate: conftest saw no document, and Checkov -- which does have
# a comparable check -- runs `--soft-fail` here (Makefile), so it reports without blocking.
# One line could undo #651/#656/#657/#658/#652's entire narrowing of ci_deploy.
#
# This is also what ADR-0027's 第3層 (a permissions boundary on ci_deploy itself) existed to
# insure against. The 2026-07-25 re-evaluation declined that layer -- its ceiling has to
# carve out s3/cloudfront/iam globally, so it would not have stopped much -- and chose this
# rule instead: it fails at PR time rather than at apply time, and the failure names the
# offending line instead of surfacing as a boundary-induced AccessDenied.
package main

aws_managed_policy_prefix := "arn:aws:iam::aws:policy/"

# Role-name suffix -> the AWS-managed policies that role legitimately carries. Suffixes,
# not full names, because every name here is `${project}-${suffix}-...` (bootstrap's
# locals.tf) and neither component is known to this file.
#
# Keep this list short and justified; each entry is a permission grant no other rule
# inspects. Anything customer-managed belongs in `infra/bootstrap/iam-ci-deploy-*.tf` or
# `infra/*.tf` as a document instead, where the wildcard/region rules can see it.
allowed_managed_attachments := {
	# PR pipelines run `terraform plan` (cd-infra.yml). Read-only, and the trust policy
	# limits it to this repo's pull_request events.
	"-ci-plan": {"arn:aws:iam::aws:policy/ReadOnlyAccess"},
	# Human-assumed via the AWS MCP Server (#571). ReadOnlyAccess plus the
	# `agent_mcp_guardrails` Deny statements, which iam_wildcard.rego does inspect.
	"-agent-mcp": {"arn:aws:iam::aws:policy/ReadOnlyAccess"},
	# ECS pulls the image and writes task logs through this (shared.tf).
	"-ecs-exec": {"arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"},
	# ADOT sidecar's trace export (observability.tf, ADR-0007).
	"-ecs-task": {"arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"},
}

is_aws_managed(arn) if {
	is_string(arn)
	startswith(arn, aws_managed_policy_prefix)
}

attachment_allowed(role, arn) if {
	is_string(role)
	some suffix, arns in allowed_managed_attachments
	endswith(role, suffix)
	arns[arn]
}

deny contains msg if {
	rc := input.resource_changes[_]
	rc.type == "aws_iam_role_policy_attachment"
	after := rc.change.after
	after != null
	is_aws_managed(after.policy_arn)
	not attachment_allowed(after.role, after.policy_arn)
	msg := sprintf(
		"%s attaches AWS-managed policy %q to role %v, which is not in this repo's allowlist (infra/policy/iam_managed_policy_attachment.rego)",
		[rc.address, after.policy_arn, object.get(after, "role", "<unknown at plan time>")],
	)
}

# `aws_iam_role`'s inline `managed_policy_arns` argument reaches the same end by another
# route. This repo doesn't use it, but a future change (or a generated project) might.
deny contains msg if {
	rc := input.resource_changes[_]
	rc.type == "aws_iam_role"
	after := rc.change.after
	after != null
	arn := after.managed_policy_arns[_]
	is_aws_managed(arn)
	not attachment_allowed(after.name, arn)
	msg := sprintf(
		"%s carries AWS-managed policy %q via managed_policy_arns, which is not in this repo's allowlist (infra/policy/iam_managed_policy_attachment.rego)",
		[rc.address, arn],
	)
}

# KNOWN LIMIT, stated so nobody mistakes it for coverage: a `policy_arn` that is unknown at
# plan time is skipped. That is what makes the rule usable at all -- an attachment to a
# customer-managed policy created in the same plan has `policy_arn = (known after apply)`,
# and those policies are already covered as documents by the other rules. The cost is that
# `policy_arn = var.something` computed at apply time slips through. The realistic drift
# this rule targets -- someone pasting a literal `arn:aws:iam::aws:policy/...` -- is caught.
