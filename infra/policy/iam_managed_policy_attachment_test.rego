package main

# Fixtures deliberately omit `tags_all`: tags.rego skips resources without it, so these
# cases exercise only the rule under test (all infra/policy/*.rego share `package main`,
# so `deny` here is the union of every rule's deny).
attachment(addr, role, arn) := {"resource_changes": [{
	"address": addr,
	"type": "aws_iam_role_policy_attachment",
	"change": {"after": {"role": role, "policy_arn": arn}},
}]}

test_deny_poweruser_on_ci_deploy if {
	# The drift this rule exists for: one line that undoes every narrowing #651-#652 made.
	violations := deny with input as attachment(
		"aws_iam_role_policy_attachment.oops",
		"demo-abc123-ci-deploy",
		"arn:aws:iam::aws:policy/PowerUserAccess",
	)

	count(violations) == 1
}

test_deny_administrator_on_ci_deploy if {
	violations := deny with input as attachment(
		"aws_iam_role_policy_attachment.oops",
		"demo-abc123-ci-deploy",
		"arn:aws:iam::aws:policy/AdministratorAccess",
	)

	count(violations) == 1
}

test_allow_readonly_on_ci_plan if {
	violations := deny with input as attachment(
		"aws_iam_role_policy_attachment.ci_plan_readonly",
		"demo-abc123-ci-plan",
		"arn:aws:iam::aws:policy/ReadOnlyAccess",
	)

	count(violations) == 0
}

test_allow_readonly_on_agent_mcp if {
	violations := deny with input as attachment(
		"aws_iam_role_policy_attachment.agent_mcp_readonly",
		"demo-abc123-agent-mcp",
		"arn:aws:iam::aws:policy/ReadOnlyAccess",
	)

	count(violations) == 0
}

test_allow_ecs_execution_managed if {
	violations := deny with input as attachment(
		"aws_iam_role_policy_attachment.ecs_execution_managed",
		"demo-sandbox-ecs-exec",
		"arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
	)

	count(violations) == 0
}

test_allow_ecs_task_xray if {
	violations := deny with input as attachment(
		"aws_iam_role_policy_attachment.ecs_task_xray",
		"demo-sandbox-ecs-task",
		"arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess",
	)

	count(violations) == 0
}

test_deny_allowlisted_role_with_other_managed_policy if {
	# The allowlist is per (role, policy) pair, not per role -- being on it for
	# ReadOnlyAccess must not admit AdministratorAccess.
	violations := deny with input as attachment(
		"aws_iam_role_policy_attachment.sneaky",
		"demo-abc123-ci-plan",
		"arn:aws:iam::aws:policy/AdministratorAccess",
	)

	count(violations) == 1
}

test_deny_when_role_is_unknown if {
	# Can't verify the target -- default to denying rather than letting an unverifiable
	# AWS-managed attachment through.
	violations := deny with input as attachment(
		"aws_iam_role_policy_attachment.dynamic",
		null,
		"arn:aws:iam::aws:policy/PowerUserAccess",
	)

	count(violations) == 1
}

test_customer_managed_policy_arn_is_not_flagged if {
	# Customer-managed policies are covered as documents by iam_wildcard.rego /
	# region_condition.rego; this rule must not double-report them.
	violations := deny with input as attachment(
		"aws_iam_role_policy_attachment.ci_deploy",
		"demo-abc123-ci-deploy",
		"arn:aws:iam::123456789012:policy/demo-abc123-deploy-platform",
	)

	count(violations) == 0
}

test_unknown_policy_arn_is_skipped if {
	# An attachment to a policy created in the same plan has policy_arn unknown. Skipping
	# it is what makes the rule usable -- see the KNOWN LIMIT note in the rule.
	violations := deny with input as attachment(
		"aws_iam_role_policy_attachment.ci_deploy",
		"demo-abc123-ci-deploy",
		null,
	)

	count(violations) == 0
}

test_deny_managed_policy_arns_argument if {
	# Same end, other route: aws_iam_role's inline managed_policy_arns argument.
	violations := deny with input as {"resource_changes": [{
		"address": "aws_iam_role.sneaky",
		"type": "aws_iam_role",
		"change": {"after": {
			"name": "demo-abc123-ci-deploy",
			"managed_policy_arns": ["arn:aws:iam::aws:policy/PowerUserAccess"],
		}},
	}]}

	count(violations) == 1
}

test_allow_managed_policy_arns_argument_when_allowlisted if {
	violations := deny with input as {"resource_changes": [{
		"address": "aws_iam_role.ci_plan",
		"type": "aws_iam_role",
		"change": {"after": {
			"name": "demo-abc123-ci-plan",
			"managed_policy_arns": ["arn:aws:iam::aws:policy/ReadOnlyAccess"],
		}},
	}]}

	count(violations) == 0
}
