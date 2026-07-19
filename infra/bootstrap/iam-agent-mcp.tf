#############################################
# Agent-only IAM role (AWS MCP Server, Claude Code)
#############################################
# #571 (docs/proposal/mcp-server-selection-proposal.md 4.2-4.5節): the CI plan/deploy
# roles above are assumed via GitHub OIDC from pipelines only. This role is separate --
# assumed by a human's IAM user, locally, from inside the devcontainer, so Claude Code can
# use the AWS MCP Server to read this AWS account. Different assumer, different credential
# path, so it is never dual-purposed with the CI roles.

data "aws_caller_identity" "current" {}

# Only a principal in this same AWS account can ever attempt to assume this role, and only
# if that principal has separately been granted sts:AssumeRole on this role's ARN (e.g. the
# human's own IAM user, per docs/aws-temporary-credentials.md method 2). That grant lives on
# the IAM user, not here -- this repo doesn't manage that user's IAM identity.
data "aws_iam_policy_document" "agent_mcp_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_iam_role" "agent_mcp" {
  name               = "${local.name_prefix}-agent-mcp"
  assume_role_policy = data.aws_iam_policy_document.agent_mcp_assume_role.json
  description        = "Read-only role assumed locally by a human via the AWS MCP Server (Claude Code); usable only for MCP-routed requests."
}

# ReadOnlyAccess is the entire baseline: write APIs are never granted, so document
# search/skill-reference tools (and any read tool a future AWS MCP Server exposes) stay
# read-only by construction.
resource "aws_iam_role_policy_attachment" "agent_mcp_readonly" {
  role       = aws_iam_role.agent_mcp.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Deny statements are exempt from infra/policy/iam_wildcard.rego's wildcard-Allow ban (the
# rule only targets Allow statements), so wildcarding here is intentional and compliant.
#
# NOTE (#571 issue comment "判明した事項1"): the proposal's own JSON example uses
# `"Condition": {"Bool": {"aws:CalledViaAWSMCP": "true"}}`, but per AWS's IAM-for-managed-MCP
# docs aws:CalledViaAWSMCP is a *string* key (the calling MCP server's service principal,
# e.g. "aws-mcp.amazonaws.com") -- it can't pair with the Bool operator. The boolean
# all-MCP-servers switch is aws:ViaAWSMCPService, which is what DenyUnlessViaAWSMCP uses
# below.
data "aws_iam_policy_document" "agent_mcp_guardrails" {
  statement {
    # BoolIfExists (not Bool) is required here: Bool alone only evaluates when the context
    # key is present, so a request with no aws:ViaAWSMCPService key at all (i.e. any plain
    # AWS CLI/SDK call using these credentials outside the MCP proxy) would silently fail to
    # match and this Deny would never fire. BoolIfExists treats an absent key as satisfying
    # the condition, so non-MCP calls are denied too -- leaked credentials for this role
    # can't be used directly.
    sid       = "DenyUnlessViaAWSMCP"
    effect    = "Deny"
    actions   = ["*"]
    resources = ["*"]

    condition {
      test     = "BoolIfExists"
      variable = "aws:ViaAWSMCPService"
      values   = ["false"]
    }
  }
  statement {
    # Blocks multi-hop assume: without this, a leaked/compromised session for this role
    # could pivot into any other role its ReadOnlyAccess-derived permissions allow it to see.
    sid    = "DenyAssumeRole"
    effect = "Deny"
    actions = [
      "sts:AssumeRole",
      "sts:AssumeRoleWithWebIdentity",
      "sts:AssumeRoleWithSAML",
    ]
    resources = ["*"]
  }
  statement {
    # Insurance, not baseline: ReadOnlyAccess alone already excludes IAM writes, but this
    # Deny stays in force even if a future change attaches another policy to this role.
    #
    # IAM rejects a wildcarded service/vendor prefix (e.g. "*:Delete*") with
    # "MalformedPolicyDocument: Action vendors ... must not contain wildcards" -- confirmed
    # applying this to real AWS (#571 issue comment). A cross-service Delete/Terminate deny
    # would need every service prefix enumerated individually, which isn't worth the
    # maintenance burden here: DenyUnlessViaAWSMCP above already denies every action
    # (destructive or not) for any request that didn't come through the MCP proxy, so it's
    # the real guardrail. This statement narrows to the one single-service wildcard IAM
    # syntax actually allows.
    sid       = "DenyDestructiveActions"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "agent_mcp_guardrails" {
  name   = "mcp-guardrails"
  role   = aws_iam_role.agent_mcp.id
  policy = data.aws_iam_policy_document.agent_mcp_guardrails.json
}
