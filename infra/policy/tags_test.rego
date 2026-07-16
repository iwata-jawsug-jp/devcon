package main

test_deny_missing_required_tag if {
	violations := deny with input as {"resource_changes": [{
		"address": "aws_s3_bucket.web",
		"type": "aws_s3_bucket",
		"change": {"after": {"tags_all": {"ManagedBy": "terraform"}}},
	}]}

	count(violations) == 1
}

test_allow_with_required_tags if {
	violations := deny with input as {"resource_changes": [{
		"address": "aws_s3_bucket.web",
		"type": "aws_s3_bucket",
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
