package main

test_deny_missing_required_tag if {
	# A resource type no other policy inspects (not aws_s3_bucket -- see s3_security.rego,
	# #296) so only tags.rego's own rule can contribute a violation here.
	violations := deny with input as {"resource_changes": [{
		"address": "aws_cloudwatch_log_group.app",
		"type": "aws_cloudwatch_log_group",
		"change": {"after": {"tags_all": {"ManagedBy": "terraform"}}},
	}]}

	count(violations) == 1
}

test_allow_with_required_tags if {
	violations := deny with input as {"resource_changes": [{
		"address": "aws_cloudwatch_log_group.app",
		"type": "aws_cloudwatch_log_group",
		"change": {"after": {"tags_all": {
			"Project": "test01",
			"Environment": "dev",
			"ManagedBy": "terraform",
		}}},
	}]}

	count(violations) == 0
}

test_resource_without_tags_all_is_ignored if {
	# Resource types that don't support tagging (e.g. a CloudFront OAC) have no
	# tags_all attribute at all -- this must not be misread as "missing tags".
	violations := deny with input as {"resource_changes": [{
		"address": "aws_cloudfront_origin_access_control.web",
		"type": "aws_cloudfront_origin_access_control",
		"change": {"after": {"name": "x"}},
	}]}

	count(violations) == 0
}

test_bootstrap_layer_requires_layer_not_environment if {
	# infra/bootstrap is applied once per account and has no environment to name, so its
	# provider tags Layer instead of Environment (#657).
	violations := deny with input as {"resource_changes": [{
		"address": "aws_iam_policy.ci_deploy_compute",
		"type": "aws_iam_policy",
		"change": {"after": {"tags_all": {"Project": "demo", "Layer": "bootstrap", "ManagedBy": "terraform"}}},
	}]}

	count(violations) == 0
}

test_bootstrap_layer_still_requires_project if {
	violations := deny with input as {"resource_changes": [{
		"address": "aws_iam_policy.untagged",
		"type": "aws_iam_policy",
		"change": {"after": {"tags_all": {"Layer": "bootstrap"}}},
	}]}

	count(violations) == 1
}

test_app_layer_still_requires_environment if {
	# A non-bootstrap resource must not escape the Environment requirement by carrying some
	# other Layer value.
	violations := deny with input as {"resource_changes": [{
		"address": "aws_cloudwatch_log_group.app",
		"type": "aws_cloudwatch_log_group",
		"change": {"after": {"tags_all": {"Project": "demo", "Layer": "app"}}},
	}]}

	count(violations) == 1
}
