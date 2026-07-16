config {
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.43.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
  # Temporary workaround (#510): GitHub's Attestations API had a breaking change
  # (2026-07-16) that removed the `bundle` field from attestation responses. tflint's
  # sigstore-go based attestation verifier doesn't handle that yet and panics with a nil
  # pointer (upstream: https://github.com/terraform-linters/tflint/issues/2591). Falling
  # back to the legacy PGP signature avoids the crash. Revert once upstream (tflint or
  # GitHub) fixes this -- tflint prints a "legacy signing key" deprecation warning while
  # this is in place.
  signature = "pgp"
}
