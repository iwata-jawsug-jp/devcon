package main

# package main is shared across infra/policy/*.rego (ADR-0017) -- fixtures below include
# only aws_s3_bucket* resource_changes so unrelated policies (tags, IAM wildcard, region
# condition, ...) have nothing to match and can't contribute stray violations.

compliant_bucket_input := {"resource_changes": [
	{
		"address": "aws_s3_bucket.web",
		"type": "aws_s3_bucket",
		"change": {"after": {"bucket": "example-web"}},
	},
	{
		"address": "aws_s3_bucket_server_side_encryption_configuration.web",
		"type": "aws_s3_bucket_server_side_encryption_configuration",
		"change": {"after": {"rule": [{"apply_server_side_encryption_by_default": {"sse_algorithm": "AES256"}}]}},
	},
	{
		"address": "aws_s3_bucket_public_access_block.web",
		"type": "aws_s3_bucket_public_access_block",
		"change": {"after": {
			"block_public_acls": true,
			"block_public_policy": true,
			"ignore_public_acls": true,
			"restrict_public_buckets": true,
		}},
	},
]}

test_allow_bucket_with_encryption_and_public_access_block if {
	violations := deny with input as compliant_bucket_input
	count(violations) == 0
}

test_deny_bucket_without_encryption_configuration if {
	# Same as compliant_bucket_input but the server_side_encryption_configuration
	# resource is missing entirely (e.g. never added, or filtered out of the plan).
	violations := deny with input as {"resource_changes": [
		compliant_bucket_input.resource_changes[0],
		compliant_bucket_input.resource_changes[2],
	]}

	count(violations) == 1
	contains(violations[_], "server_side_encryption_configuration")
}

test_deny_bucket_without_public_access_block if {
	violations := deny with input as {"resource_changes": [
		compliant_bucket_input.resource_changes[0],
		compliant_bucket_input.resource_changes[1],
	]}

	count(violations) == 1
	contains(violations[_], "public_access_block")
}

test_deny_public_access_block_not_fully_restrictive if {
	violations := deny with input as {"resource_changes": [
		compliant_bucket_input.resource_changes[0],
		compliant_bucket_input.resource_changes[1],
		{
			"address": "aws_s3_bucket_public_access_block.web",
			"type": "aws_s3_bucket_public_access_block",
			"change": {"after": {
				"block_public_acls": true,
				"block_public_policy": true,
				"ignore_public_acls": true,
				"restrict_public_buckets": false,
			}},
		},
	]}

	count(violations) == 1
	contains(violations[_], "public_access_block")
}

test_deny_bucket_missing_both if {
	violations := deny with input as {"resource_changes": [compliant_bucket_input.resource_changes[0]]}

	count(violations) == 2
}

test_bucket_being_destroyed_is_ignored if {
	# change.after == null (a pure delete) must not be misread as "encryption missing".
	violations := deny with input as {"resource_changes": [{
		"address": "aws_s3_bucket.web",
		"type": "aws_s3_bucket",
		"change": {"after": null},
	}]}

	count(violations) == 0
}
