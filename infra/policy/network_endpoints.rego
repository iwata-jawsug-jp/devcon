package main

# infra/network.tf's private route table is intentionally NAT-less (egress only via VPC
# endpoints, #369). Hardcodes this template's fixed resource address rather than a
# structural heuristic -- this is a template-specific design assertion, not a generic rule.
deny contains msg if {
	rc := input.resource_changes[_]
	rc.address == "aws_route_table.private"
	route := rc.change.after.route[_]
	route.cidr_block == "0.0.0.0/0"
	msg := sprintf("%s has a default route (0.0.0.0/0) -- this template's private subnets are designed to be NAT-less (egress only via VPC endpoints); a NAT/IGW default route here is unexpected", [rc.address])
}

required_interface_endpoint_suffixes := {".ecr.api", ".ecr.dkr", ".logs", ".secretsmanager", ".cognito-idp"}

endpoint_exists(suffix) if {
	rc := input.resource_changes[_]
	rc.type == "aws_vpc_endpoint"
	rc.change.after.vpc_endpoint_type == "Interface"
	endswith(rc.change.after.service_name, suffix)
}

# Guard so this rule only activates against a genuine full app-layer plan (identified by
# the presence of the private route table resource) -- without this, "not
# endpoint_exists(suffix)" would fire on ANY input lacking VPC endpoints, including every
# other policy file's unrelated test fixtures (package main is shared across
# infra/policy/*.rego, see ADR-0017's testing gotcha note).
is_app_layer_plan if {
	some rc in input.resource_changes
	rc.address == "aws_route_table.private"
}

deny contains msg if {
	is_app_layer_plan
	some suffix in required_interface_endpoint_suffixes
	not endpoint_exists(suffix)
	msg := sprintf("missing required VPC interface endpoint (service name ending %q) -- private subnets have no NAT gateway, so ECS tasks can't reach this service without it (#369 regression)", [suffix])
}
