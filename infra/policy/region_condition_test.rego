package main

test_deny_state_shape_missing_condition if {
	stmt := {"Sid": "EcsProjectResources", "Effect": "Allow", "Action": ["ecs:UpdateService"], "Resource": "*"}
	policy_json := json.marshal({"Version": "2012-10-17", "Statement": [stmt]})
	resource := {
		"address": "aws_iam_role_policy.ci_deploy_compute",
		"type": "aws_iam_role_policy",
		"values": {"policy": policy_json},
	}
	violations := deny with input as {"values": {"root_module": {"resources": [resource]}}}
	count(violations) == 1
}

test_allow_state_shape_with_condition if {
	stmt := {
		"Sid": "EcsProjectResources", "Effect": "Allow", "Action": ["ecs:UpdateService"], "Resource": "*",
		"Condition": {"StringEquals": {"aws:RequestedRegion": "ap-northeast-1"}},
	}
	policy_json := json.marshal({"Version": "2012-10-17", "Statement": [stmt]})
	resource := {
		"address": "aws_iam_role_policy.ci_deploy_compute",
		"type": "aws_iam_role_policy",
		"values": {"policy": policy_json},
	}
	violations := deny with input as {"values": {"root_module": {"resources": [resource]}}}
	count(violations) == 0
}

test_deny_plan_shape_missing_condition if {
	stmt := {"Sid": "EcsProjectResources", "Effect": "Allow", "Action": "ecs:UpdateService", "Resource": "*"}
	policy_json := json.marshal({"Version": "2012-10-17", "Statement": [stmt]})
	rc := {
		"address": "aws_iam_role_policy.ci_deploy_compute",
		"type": "aws_iam_role_policy",
		"change": {"after": {"policy": policy_json}},
	}
	violations := deny with input as {"resource_changes": [rc]}
	count(violations) == 1
}

test_allow_iam_s3_cloudfront_exempt_without_condition if {
	# IAM/S3/CloudFront are intentionally exempt (global-scope services) -- must not be flagged.
	stmt := {"Sid": "IamPassRole", "Effect": "Allow", "Action": "iam:PassRole", "Resource": "*"}
	policy_json := json.marshal({"Version": "2012-10-17", "Statement": [stmt]})
	resource := {
		"address": "aws_iam_role_policy.ci_deploy_iam",
		"type": "aws_iam_role_policy",
		"values": {"policy": policy_json},
	}
	violations := deny with input as {"values": {"root_module": {"resources": [resource]}}}
	count(violations) == 0
}

test_allow_planned_values_shape_with_condition if {
	stmt := {
		"Sid": "RdsProjectResources", "Effect": "Allow", "Action": ["rds:CreateDBInstance"], "Resource": "*",
		"Condition": {"StringEquals": {"aws:RequestedRegion": "ap-northeast-1"}},
	}
	policy_json := json.marshal({"Version": "2012-10-17", "Statement": [stmt]})
	resource := {
		"address": "aws_iam_role_policy.ci_deploy_data",
		"type": "aws_iam_role_policy",
		"values": {"policy": policy_json},
	}
	violations := deny with input as {"planned_values": {"root_module": {"resources": [resource]}}}
	count(violations) == 0
}

test_deny_effect_statements_not_flagged if {
	stmt := {"Sid": "DenyEverythingElse", "Effect": "Deny", "Action": "ecs:*", "Resource": "*"}
	policy_json := json.marshal({"Version": "2012-10-17", "Statement": [stmt]})
	resource := {
		"address": "aws_iam_role_policy.explicit_deny",
		"type": "aws_iam_role_policy",
		"values": {"policy": policy_json},
	}
	violations := deny with input as {"values": {"root_module": {"resources": [resource]}}}
	count(violations) == 0
}
