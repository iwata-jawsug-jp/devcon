package main

test_deny_wildcard_string_action if {
	violations := deny with input as {"resource_changes": [{
		"address": "aws_iam_role_policy.bad",
		"type": "aws_iam_role_policy",
		"change": {"after": {"policy": json.marshal({
			"Version": "2012-10-17",
			"Statement": [{"Sid": "TooBroad", "Effect": "Allow", "Action": "s3:*", "Resource": "*"}],
		})}},
	}]}

	count(violations) == 1
}

test_deny_literal_wildcard_action_in_list if {
	violations := deny with input as {"resource_changes": [{
		"address": "aws_iam_policy.bad2",
		"type": "aws_iam_policy",
		"change": {"after": {"policy": json.marshal({
			"Version": "2012-10-17",
			"Statement": [{"Sid": "Everything", "Effect": "Allow", "Action": ["s3:GetObject", "*"], "Resource": "*"}],
		})}},
	}]}

	count(violations) == 1
}

test_allow_scoped_action if {
	violations := deny with input as {"resource_changes": [{
		"address": "aws_iam_role_policy.good",
		"type": "aws_iam_role_policy",
		"change": {"after": {"policy": json.marshal({
			"Version": "2012-10-17",
			"Statement": [{"Sid": "Scoped", "Effect": "Allow", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::bucket/*"}],
		})}},
	}]}

	count(violations) == 0
}

test_explicit_deny_statements_are_not_flagged if {
	# An explicit Deny statement using "*" is a guardrail, not a broad grant -- must not flag it.
	violations := deny with input as {"resource_changes": [{
		"address": "aws_iam_role_policy.explicit_deny",
		"type": "aws_iam_role_policy",
		"change": {"after": {"policy": json.marshal({
			"Version": "2012-10-17",
			"Statement": [{"Sid": "DenyEverythingElse", "Effect": "Deny", "Action": "*", "Resource": "*"}],
		})}},
	}]}

	count(violations) == 0
}

test_non_iam_resource_type_is_ignored if {
	# All infra/policy/*.rego files share `package main`, so `deny` here is the union of
	# every policy's deny rule (not just this file's) -- give this fixture complete tags
	# so it can't also trip tags.rego's rule.
	violations := deny with input as {"resource_changes": [{
		"address": "aws_s3_bucket.web",
		"type": "aws_s3_bucket",
		"change": {"after": {"tags_all": {"Project": "x", "Environment": "dev"}}},
	}]}

	count(violations) == 0
}
