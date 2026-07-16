package main

all_endpoints_present := [
	{"address": "aws_vpc_endpoint.interface[\"ecr_api\"]", "type": "aws_vpc_endpoint", "change": {"after": {"vpc_endpoint_type": "Interface", "service_name": "com.amazonaws.ap-northeast-1.ecr.api"}}},
	{"address": "aws_vpc_endpoint.interface[\"ecr_dkr\"]", "type": "aws_vpc_endpoint", "change": {"after": {"vpc_endpoint_type": "Interface", "service_name": "com.amazonaws.ap-northeast-1.ecr.dkr"}}},
	{"address": "aws_vpc_endpoint.interface[\"logs\"]", "type": "aws_vpc_endpoint", "change": {"after": {"vpc_endpoint_type": "Interface", "service_name": "com.amazonaws.ap-northeast-1.logs"}}},
	{"address": "aws_vpc_endpoint.interface[\"secretsmanager\"]", "type": "aws_vpc_endpoint", "change": {"after": {"vpc_endpoint_type": "Interface", "service_name": "com.amazonaws.ap-northeast-1.secretsmanager"}}},
	{"address": "aws_vpc_endpoint.interface[\"cognito_idp\"]", "type": "aws_vpc_endpoint", "change": {"after": {"vpc_endpoint_type": "Interface", "service_name": "com.amazonaws.ap-northeast-1.cognito-idp"}}},
]

private_rt_no_default_route := {
	"address": "aws_route_table.private",
	"type": "aws_route_table",
	"change": {"after": {"route": []}},
}

private_rt_with_default_route := {
	"address": "aws_route_table.private",
	"type": "aws_route_table",
	"change": {"after": {"route": [{"cidr_block": "0.0.0.0/0", "nat_gateway_id": "nat-123"}]}},
}

test_allow_natless_with_all_endpoints if {
	rcs := array.concat(all_endpoints_present, [private_rt_no_default_route])
	violations := deny with input as {"resource_changes": rcs}
	count(violations) == 0
}

test_deny_default_route_on_private_rt if {
	rcs := array.concat(all_endpoints_present, [private_rt_with_default_route])
	violations := deny with input as {"resource_changes": rcs}
	count(violations) == 1
}

test_deny_missing_cognito_idp_endpoint if {
	# Drop the last element (cognito_idp) from the required list.
	partial := array.slice(all_endpoints_present, 0, 4)
	rcs := array.concat(partial, [private_rt_no_default_route])
	violations := deny with input as {"resource_changes": rcs}
	count(violations) == 1
}

test_deny_no_endpoints_at_all if {
	violations := deny with input as {"resource_changes": [private_rt_no_default_route]}
	count(violations) == 5
}
