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

deny contains msg if {
	rc := input.resource_changes[_]
	target_types[rc.type]
	rc.change.after.policy != null
	doc := json.unmarshal(rc.change.after.policy)
	stmt := doc.Statement[_]
	stmt.Effect == "Allow"
	action := action_list(stmt)[_]
	is_wildcard_action(action)
	msg := sprintf("%s has an overly broad IAM action %q (Allow + wildcard)", [rc.address, action])
}
