# Required-tags policy (#296).
#
# `default_tags` on the aws provider (providers.tf) already merges Project/Environment/
# ManagedBy into every taggable resource, so this should always pass today -- it exists as
# a regression guard (e.g. a resource created via a differently-configured provider alias,
# or a future AWS resource type whose default_tags support turns out to be incomplete),
# not because a violation is currently expected.
package main

# Which second dimension is required depends on the layer (#657, when `conftest test` started
# covering `infra/bootstrap` too). The app layer is deployed once per environment and tags
# `Environment`; `infra/bootstrap` is applied once per *account* and has no environment to
# name, so its provider tags `Layer = "bootstrap"` instead (infra/bootstrap/providers.tf).
# Requiring `Environment` there would flag every bootstrap resource for a tag that would be
# meaningless if it existed.
resource_layer(after) := object.get(after.tags_all, "Layer", "")

required_tags(after) := {"Project", "Layer"} if resource_layer(after) == "bootstrap"

required_tags(after) := {"Project", "Environment"} if resource_layer(after) != "bootstrap"

deny contains msg if {
	rc := input.resource_changes[_]
	after := rc.change.after
	after != null

	# Resource types that don't support tagging at all (e.g. aws_cloudfront_origin_access_control)
	# have no `tags_all` attribute -- `is_object` is false (not an error) for that undefined
	# value, so untaggable resources are skipped rather than flagged as "missing tags".
	is_object(after.tags_all)

	required := required_tags(after)
	present_keys := {k | after.tags_all[k]}
	missing := required - present_keys
	count(missing) > 0
	msg := sprintf("%s (%s) is missing required tag(s): %v", [rc.address, rc.type, missing])
}
