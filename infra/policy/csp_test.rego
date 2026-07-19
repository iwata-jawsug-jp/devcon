package main

test_deny_missing_connect_src if {
	rc := {
		"address": "aws_cloudfront_response_headers_policy.web_security_headers",
		"type": "aws_cloudfront_response_headers_policy",
		"change": {"after": {"security_headers_config": [{"content_security_policy": [{"content_security_policy": "default-src 'self'; script-src 'self'"}]}]}},
	}
	violations := deny with input as {"resource_changes": [rc]}
	count(violations) == 1
}

test_deny_connect_src_without_cognito if {
	rc := {
		"address": "aws_cloudfront_response_headers_policy.web_security_headers",
		"type": "aws_cloudfront_response_headers_policy",
		"change": {"after": {"security_headers_config": [{"content_security_policy": [{"content_security_policy": "default-src 'self'; connect-src 'self'"}]}]}},
	}
	violations := deny with input as {"resource_changes": [rc]}
	count(violations) == 1
}

test_allow_connect_src_with_cognito if {
	rc := {
		"address": "aws_cloudfront_response_headers_policy.web_security_headers",
		"type": "aws_cloudfront_response_headers_policy",
		"change": {"after": {"security_headers_config": [{"content_security_policy": [{"content_security_policy": "default-src 'self'; connect-src 'self' https://cognito-idp.ap-northeast-1.amazonaws.com https://foo.auth.ap-northeast-1.amazoncognito.com"}]}]}},
	}
	violations := deny with input as {"resource_changes": [rc]}
	count(violations) == 0
}

test_non_matching_resource_type_ignored if {
	# Not aws_s3_bucket -- see s3_security.rego (#296) -- so this can't also trip that
	# policy's rules under the `package main` shared-input gotcha (ADR-0017).
	rc := {"address": "aws_cloudwatch_log_group.app", "type": "aws_cloudwatch_log_group", "change": {"after": {"tags_all": {"Project": "x", "Environment": "y"}}}}
	violations := deny with input as {"resource_changes": [rc]}
	count(violations) == 0
}
