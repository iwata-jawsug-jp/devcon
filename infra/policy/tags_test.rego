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
