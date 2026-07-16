# Required-tags policy (#296).
#
# `default_tags` on the aws provider (providers.tf) already merges Project/Environment/
# ManagedBy into every taggable resource, so this should always pass today -- it exists as
# a regression guard (e.g. a resource created via a differently-configured provider alias,
# or a future AWS resource type whose default_tags support turns out to be incomplete),
# not because a violation is currently expected.
package main

deny contains msg if {
	rc := input.resource_changes[_]
	after := rc.change.after
	after != null

	# Resource types that don't support tagging at all (e.g. aws_cloudfront_origin_access_control)
	# have no `tags_all` attribute -- `is_object` is false (not an error) for that undefined
	# value, so untaggable resources are skipped rather than flagged as "missing tags".
	is_object(after.tags_all)

	required := {"Project", "Environment"}
	present_keys := {k | after.tags_all[k]}
	missing := required - present_keys
	count(missing) > 0
	msg := sprintf("%s (%s) is missing required tag(s): %v", [rc.address, rc.type, missing])
}
