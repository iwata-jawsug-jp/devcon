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
	# and a resource type no other policy inspects (not aws_s3_bucket -- see
	# s3_security.rego, #296) so it can't also trip tags.rego's or s3_security.rego's rules.
	violations := deny with input as {"resource_changes": [{
		"address": "aws_cloudwatch_log_group.app",
		"type": "aws_cloudwatch_log_group",
		"change": {"after": {"tags_all": {"Project": "x", "Environment": "dev"}}},
	}]}

	count(violations) == 0
}

test_permissions_boundary_policy_is_exempt if {
	# A permissions boundary is a ceiling, not a grant -- `Action: "*"` in one is normal
	# (ADR-0027 第1層, #656). Identified by the `-boundary` name suffix.
	violations := deny with input as {"resource_changes": [{
		"address": "aws_iam_policy.app_role_boundary",
		"type": "aws_iam_policy",
		"change": {"after": {
			"name": "demo-abc123-app-role-boundary",
			"policy": json.marshal({
				"Version": "2012-10-17",
				"Statement": [{"Sid": "AllowWithinProjectRegion", "Effect": "Allow", "Action": "*", "Resource": "*"}],
			}),
		}},
	}]}

	count(violations) == 0
}

test_non_boundary_name_with_same_document_is_still_denied if {
	# The exemption must stay a narrow, name-based carve-out rather than a way to opt out of
	# the rule: the identical document under any other name is still a violation.
	violations := deny with input as {"resource_changes": [{
		"address": "aws_iam_policy.sneaky",
		"type": "aws_iam_policy",
		"change": {"after": {
			"name": "demo-abc123-deploy-compute",
			"policy": json.marshal({
				"Version": "2012-10-17",
				"Statement": [{"Sid": "AllowEverything", "Effect": "Allow", "Action": "*", "Resource": "*"}],
			}),
		}},
	}]}

	count(violations) == 1
}

# --- ADR-0027 第2層 (#658): scoped wildcards are allowed, unscoped ones are not ---

test_allow_service_wildcard_on_scoped_resource_with_region_condition if {
	# `ecr:*` on this project's repositories, in one region: both the resource and region
	# axes still bound it, which is the whole premise of 第2層.
	violations := deny with input as {"resource_changes": [{
		"address": "aws_iam_policy.ci_deploy_compute",
		"type": "aws_iam_policy",
		"change": {"after": {
			"name": "demo-abc123-deploy-compute",
			"policy": json.marshal({"Version": "2012-10-17", "Statement": [{
				"Sid": "EcrProjectRepo",
				"Effect": "Allow",
				"Action": "ecr:*",
				"Resource": "arn:aws:ecr:*:*:repository/demo-*",
				"Condition": {"StringEquals": {"aws:RequestedRegion": "ap-northeast-1"}},
			}]}),
		}},
	}]}

	count(violations) == 0
}

test_allow_service_wildcard_without_region_condition_for_non_region_scoped_service if {
	# S3ProjectBuckets (#45) and CloudWatchDashboard (#258) deliberately carry no
	# aws:RequestedRegion condition. region_condition.rego does not govern s3/cloudwatch, so
	# requiring one here would flag a statement the other rule is happy with.
	violations := deny with input as {"resource_changes": [{
		"address": "aws_iam_policy.ci_deploy_storage_cdn",
		"type": "aws_iam_policy",
		"change": {"after": {
			"name": "demo-abc123-deploy-storage-cdn",
			"policy": json.marshal({"Version": "2012-10-17", "Statement": [{
				"Sid": "S3ProjectBuckets",
				"Effect": "Allow",
				"Action": "s3:*",
				"Resource": ["arn:aws:s3:::demo-*", "arn:aws:s3:::demo-*/*"],
			}]}),
		}},
	}]}

	count(violations) == 0
}

test_deny_service_wildcard_missing_region_condition_for_region_scoped_service if {
	# Same shape, but ECR *is* region-governed: dropping the condition must still be a
	# violation, or 第2層 would have quietly retired the region axis too.
	violations := deny with input as {"resource_changes": [{
		"address": "aws_iam_policy.ci_deploy_compute",
		"type": "aws_iam_policy",
		"change": {"after": {
			"name": "demo-abc123-deploy-compute",
			"policy": json.marshal({"Version": "2012-10-17", "Statement": [{
				"Sid": "EcrNoRegion",
				"Effect": "Allow",
				"Action": "ecr:*",
				"Resource": "arn:aws:ecr:*:*:repository/demo-*",
			}]}),
		}},
	}]}

	# One from this rule, one from region_condition.rego (same package) -- both are correct.
	count(violations) == 2
}

test_deny_service_wildcard_on_unscoped_resource if {
	# The case 第2層 explicitly does not cover: Resource "*" means the action list was the
	# only guardrail, so widening it is the same as granting the service outright.
	violations := deny with input as {"resource_changes": [{
		"address": "aws_iam_policy.ci_deploy_storage_cdn",
		"type": "aws_iam_policy",
		"change": {"after": {
			"name": "demo-abc123-deploy-storage-cdn",
			"policy": json.marshal({"Version": "2012-10-17", "Statement": [{
				"Sid": "CloudFrontEverything",
				"Effect": "Allow",
				"Action": "cloudfront:*",
				"Resource": "*",
			}]}),
		}},
	}]}

	count(violations) == 1
}

test_deny_partially_scoped_resource_list if {
	# A list containing "*" alongside real ARNs is unscoped -- the "*" element decides.
	violations := deny with input as {"resource_changes": [{
		"address": "aws_iam_policy.mixed",
		"type": "aws_iam_policy",
		"change": {"after": {
			"name": "demo-abc123-deploy-mixed",
			"policy": json.marshal({"Version": "2012-10-17", "Statement": [{
				"Sid": "Mixed",
				"Effect": "Allow",
				"Action": "sqs:*",
				"Resource": ["arn:aws:sqs:*:*:demo-*", "*"],
				"Condition": {"StringEquals": {"aws:RequestedRegion": "ap-northeast-1"}},
			}]}),
		}},
	}]}

	count(violations) == 1
}

test_deny_bare_wildcard_even_on_scoped_resource if {
	# `Action: "*"` grants IAM/STS too, which turns any grant into every grant -- a tight
	# resource scope does not redeem it.
	violations := deny with input as {"resource_changes": [{
		"address": "aws_iam_policy.everything",
		"type": "aws_iam_policy",
		"change": {"after": {
			"name": "demo-abc123-deploy-everything",
			"policy": json.marshal({"Version": "2012-10-17", "Statement": [{
				"Sid": "Everything",
				"Effect": "Allow",
				"Action": "*",
				"Resource": "arn:aws:ecr:*:*:repository/demo-*",
				"Condition": {"StringEquals": {"aws:RequestedRegion": "ap-northeast-1"}},
			}]}),
		}},
	}]}

	count(violations) == 1
}
