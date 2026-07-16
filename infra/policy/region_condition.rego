package main

# target_types / action_list are defined in iam_wildcard.rego -- shared via package main,
# not redefined here.

region_scoped_action_prefixes := {"ec2", "ecs", "ecr", "rds", "logs", "elasticloadbalancing", "application-autoscaling"}

policy_docs contains {"address": rc.address, "policy": rc.change.after.policy} if {
	rc := input.resource_changes[_]
	target_types[rc.type]
	rc.change.after.policy != null
}

policy_docs contains {"address": res.address, "policy": res.values.policy} if {
	root := object.get(input, "values", null)
	root != null
	res := root.root_module.resources[_]
	target_types[res.type]
	res.values.policy != null
}

policy_docs contains {"address": res.address, "policy": res.values.policy} if {
	root := object.get(input, "planned_values", null)
	root != null
	res := root.root_module.resources[_]
	target_types[res.type]
	res.values.policy != null
}

action_prefix(action) := split(action, ":")[0]

is_region_scoped(stmt) if {
	some action in action_list(stmt)
	region_scoped_action_prefixes[action_prefix(action)]
}

has_region_condition(stmt) if {
	stmt.Condition.StringEquals["aws:RequestedRegion"]
}

deny contains msg if {
	doc := policy_docs[_]
	parsed := json.unmarshal(doc.policy)
	stmt := parsed.Statement[_]
	stmt.Effect == "Allow"
	is_region_scoped(stmt)
	not has_region_condition(stmt)
	msg := sprintf("%s: statement %v grants a region-scoped action without an aws:RequestedRegion condition", [doc.address, object.get(stmt, "Sid", "<no Sid>")])
}
