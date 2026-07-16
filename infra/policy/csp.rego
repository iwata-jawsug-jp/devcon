package main

deny contains msg if {
	rc := input.resource_changes[_]
	rc.type == "aws_cloudfront_response_headers_policy"
	csp := rc.change.after.security_headers_config[0].content_security_policy[0].content_security_policy
	directives := split(csp, "; ")
	connect_src_directives := [d | d := directives[_]; startswith(d, "connect-src")]
	count(connect_src_directives) == 0
	msg := sprintf("%s: Content-Security-Policy has no connect-src directive", [rc.address])
}

deny contains msg if {
	rc := input.resource_changes[_]
	rc.type == "aws_cloudfront_response_headers_policy"
	csp := rc.change.after.security_headers_config[0].content_security_policy[0].content_security_policy
	directives := split(csp, "; ")
	connect_src := [d | d := directives[_]; startswith(d, "connect-src")][0]
	not contains(connect_src, "cognito")
	msg := sprintf("%s: Content-Security-Policy connect-src doesn't appear to allow a Cognito origin: %q", [rc.address, connect_src])
}
