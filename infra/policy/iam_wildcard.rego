# Deny wildcard Allow actions in identity policies (#296's "IAM ワイルドカードアクション禁止"
# candidate). Scoped to Allow statements only -- an explicit Deny with a wildcard action is a
# guardrail (deny-everything-else), not an over-broad grant, so it's intentionally not flagged.
#
# Complements, and does not replace, ADR-0009's `aws accessanalyzer validate-policy` check
# (#340): that one catches structurally-invalid condition keys via a live AWS API call; this
# one is a pure offline style/convention rule (no AWS credentials needed), so it can run
# anywhere a plan JSON is available.
package main

target_types := {"aws_iam_policy", "aws_iam_role_policy", "aws_iam_user_policy"}

# `Action` in a rendered policy document can be either a single string or a JSON array --
# normalize both shapes to an array.
action_list(stmt) := a if {
	is_array(stmt.Action)
	a := stmt.Action
}

action_list(stmt) := a if {
	is_string(stmt.Action)
	a := [stmt.Action]
}

is_wildcard_action(a) if {
	a == "*"
}

is_wildcard_action(a) if {
	endswith(a, ":*")
}

# A *bare* `"*"` is never acceptable in an Allow, however tightly the resource is scoped:
# it grants every service, including the IAM/STS calls that turn any grant into every
# grant. `"<service>:*"` is a different proposition -- see scoped_wildcard_allowed below.
is_unscoped_wildcard_action(a) if {
	a == "*"
}

# ADR-0027 第2層 (#658): a wildcard action is acceptable when the OTHER axes are still
# doing the work. The rule used to be "Allow + wildcard action = violation", full stop,
# which could not tell `ecr:*` on `repository/<project>-*` in one region apart from
# `ecr:*` on `*` everywhere -- so the only way to satisfy it was to enumerate actions, and
# enumerating actions is what produced the #258 / #600 / #640 round-trips (every time the
# AWS provider called one more API against a resource this role already fully owns, a real
# apply failed and someone added a line).
#
# Required for the exemption:
#   1. `Resource` is not "*" -- the ARN axis must still bound the blast radius.
#   2. For the services region_condition.rego governs, the aws:RequestedRegion condition
#      must be present, so the region axis holds too.
#
# Note what (2) does NOT say: "every scoped wildcard needs a region condition". Two
# statements are deliberately region-condition-free and would be flagged by that stricter
# reading -- S3ProjectBuckets (`aws s3 sync` can route via the global/us-east-1 endpoint,
# #45) and CloudWatchDashboard (dashboard ARNs have no region segment, #258). Keeping this
# aligned with region_condition.rego's own service list is what stops the two rules from
# contradicting each other.
scoped_wildcard_allowed(stmt) if {
	resource_is_scoped(stmt)
	not missing_required_region_condition(stmt)
}

resource_is_scoped(stmt) if {
	resources := resource_list(stmt)
	count(resources) > 0
	every r in resources {
		r != "*"
	}
}

resource_list(stmt) := r if {
	is_array(stmt.Resource)
	r := stmt.Resource
}

resource_list(stmt) := [stmt.Resource] if is_string(stmt.Resource)

missing_required_region_condition(stmt) if {
	is_region_scoped(stmt)
	not has_region_condition(stmt)
}

# Permissions boundary policies are exempt: a boundary is a ceiling, not a grant, and
# `Action: "*"` inside one is normal -- it is the *intersection* with the role's identity
# policies that decides the effective permissions (ADR-0027 第1層, #656). The convention is
# the `-boundary` name suffix, which infra/bootstrap/iam-app-role-boundary.tf follows; a
# policy that grants permissions must never be named that way.
#
# Deliberately narrow: matching on the name (not on "any policy containing Action: *")
# keeps the exemption from becoming a way to opt out of the rule -- see
# iam_wildcard_test.rego, which pins that a differently-named policy with the same document
# is still denied.
is_boundary_policy(rc) if {
	name := rc.change.after.name
	is_string(name)
	endswith(name, "-boundary")
}

deny contains msg if {
	rc := input.resource_changes[_]
	target_types[rc.type]
	not is_boundary_policy(rc)
	rc.change.after.policy != null
	doc := json.unmarshal(rc.change.after.policy)
	stmt := doc.Statement[_]
	stmt.Effect == "Allow"
	action := action_list(stmt)[_]
	is_wildcard_action(action)

	# Bare "*" is reported by the rule below instead, so each violation yields exactly one
	# message rather than two overlapping ones.
	not is_unscoped_wildcard_action(action)
	not scoped_wildcard_allowed(stmt)
	msg := sprintf("%s has an overly broad IAM action %q (Allow + wildcard on an unscoped resource)", [rc.address, action])
}

deny contains msg if {
	rc := input.resource_changes[_]
	target_types[rc.type]
	not is_boundary_policy(rc)
	rc.change.after.policy != null
	doc := json.unmarshal(rc.change.after.policy)
	stmt := doc.Statement[_]
	stmt.Effect == "Allow"
	action := action_list(stmt)[_]
	is_unscoped_wildcard_action(action)
	msg := sprintf("%s grants every action (%q) in an Allow statement -- scope it to a service at minimum", [rc.address, action])
}
