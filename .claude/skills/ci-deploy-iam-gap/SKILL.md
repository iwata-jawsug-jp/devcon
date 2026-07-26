---
name: ci-deploy-iam-gap
description: Diagnose and fix missing ci_deploy IAM permissions in infra/bootstrap/iam-ci-deploy-*.tf. Use reactively when a sandbox terraform apply/destroy fails with AccessDenied against the ci_deploy role, or proactively before applying Terraform changes that introduce a new AWS resource type/pattern not yet covered by an existing ci_deploy statement.
allowed-tools: Read, Edit, Grep, Glob, Bash, WebSearch, WebFetch, mcp__aws__aws___search_documentation, mcp__aws__aws___read_documentation, mcp__aws__aws___retrieve_skill
argument-hint: <AccessDenied error text> | <new resource description>
---

# ci-deploy-iam-gap

## Overview

`infra/bootstrap/iam-ci-deploy-*.tf` grants the CI deploy role only what's demonstrably
needed, split by area file, with every non-obvious action justified by a comment explaining
the concrete mechanism that requires it. Missing permissions in this role surface almost
exclusively through real AWS calls — a sandbox `terraform apply`/`destroy` failing with
`AccessDenied` — because CI's own plan/apply never exercises the deploy role against real
resources the way a sandbox run does. This has already cost two full rounds of real
apply/destroy cycles to fully surface (#631: 2 gaps found this way; #640: 2 more). This skill
turns that ad-hoc CloudTrail archaeology into a repeatable procedure, covering both the moment
after a real failure and the moment before adding a resource type likely to need something
not yet granted.

## When to Use

- **Mode A (reactive):** a sandbox `terraform apply`/`destroy` just failed with `AccessDenied`
  against the ci_deploy role.
- **Mode B (proactive):** `infra/` is about to gain a new AWS resource *type* (not just
  another instance of an existing type) that ci_deploy will need to create/manage/destroy.
- **Mode C (static):** any time you need to know what the *currently attached* policies decide
  for a given action — verifying a condition-guarded statement (the `iam:PermissionsBoundary`
  ones added in #656), proving a `Deny` is really in force, or separating "condition didn't
  match" from "action is missing" in Mode A. Read-only and free; use it before spending a
  sandbox cycle, not instead of one.

Do not use this skill to add broad or wildcard permissions "just in case" — every addition
needs a concrete, stated justification, and per repo rule, real sandbox verification before
it's considered done (see `docs/sandbox.md`).

## Inputs

- Mode A: the failing command's output, the ci_deploy role ARN/session name, the sandbox AWS
  account/region, and the approximate failure timestamp (for CloudTrail lookups).
- Mode B: the new resource block(s) being added and which area they conceptually belong to.

## Area file map (`infra/bootstrap/`)

- `iam-ci-deploy-auth.tf` — Cognito (user pool / client / resource server / Hosted UI domain)
- `iam-ci-deploy-compute.tf` — ECS cluster/service/task-def/autoscaling, ECR, ALB, container-image Lambda
- `iam-ci-deploy-data.tf` — RDS, Secrets Manager, and the KMS grants their default-key encryption implies
- `iam-ci-deploy-iam.tf` — this project's own ECS/Lambda roles + PassRole + AWS service-linked roles
- `iam-ci-deploy-messaging.tf` — SQS, Lambda function actions, Lambda event source mappings
- `iam-ci-deploy-network.tf` — VPC/subnets/route tables/security groups/VPC endpoints/ENIs
- `iam-ci-deploy-observability.tf` — SNS alerts, CloudWatch alarms/dashboard
- `iam-ci-deploy-storage-cdn.tf` — S3, CloudFront, and their default-key KMS grants

If a resource doesn't obviously fit one of these, say so explicitly rather than guessing a file
— that's a signal the area taxonomy itself may need to grow. This happens most often when a
new resource is a variant of something that already has two homes (e.g. a second Lambda
function serving external HTTP directly, when the existing area split is "worker Lambda →
messaging.tf" vs. "ALB-fronted API → compute.tf"): present the ambiguity and the candidate
files to the user instead of picking one silently — don't force a fit that isn't there yet.

## Method — Mode A (reactive: AccessDenied → fix)

1. **Get the exact denied action.** If the terraform output already names
   `... not authorized to perform: <action> on resource: <arn> ...`, skip to step 3.
2. **If not in the error text, query CloudTrail** for the ci_deploy role in the failure window:
   ```
   aws cloudtrail lookup-events \
     --lookup-attributes AttributeKey=Username,AttributeValue=<ci_deploy-role-session> \
     --start-time <approx-failure-time-minus-5min> \
     --query "Events[?contains(CloudTrailEvent, 'errorCode') && contains(CloudTrailEvent, 'AccessDenied')]"
   ```
   Extract `eventSource`/`eventName` from the matching event(s).
2b. **Before hunting for a missing action, rule out the permissions boundary** (ADR-0027 第1層,
   #656). Since the boundary landed, a deny can mean "the grant is there but the *condition*
   didn't match" rather than "the action is missing", and the two look identical in the error
   text. Three signatures worth knowing:
   - **`iam:AttachRolePolicy` / `PutRolePolicy` / `DetachRolePolicy` denied against a role that
     exists.** For those actions `iam:PermissionsBoundary` refers to the boundary *currently on
     the target role*, so this is what you get for a role created before the boundary existed —
     or for one carrying a **stale boundary ARN after a re-bootstrap**, since the policy name
     embeds `var.resource_name_suffix` and a fresh bootstrap mints a new suffix. Terraform
     self-heals the latter (the SSM value changes → the role update runs
     `PutRolePermissionsBoundary` first, which *is* allowed), so check whether the apply was
     interrupted before reaching the role update.
   - **`iam:CreateRole` denied.** The new role is being created without a boundary at all — the
     app layer is missing `permissions_boundary`, or read it from a different account/region's
     SSM parameter.
   - **The deployed app gets AccessDenied at runtime even though its task role grants the
     action.** That is the ceiling, not the grant: the boundary only allows
     `aws:RequestedRegion = <project region>`, so cross-region calls and global services
     (IAM/STS/Organizations) are capped no matter what the identity policy says. Confirm with
     Mode C against the *task role*, then decide deliberately whether to widen the ceiling —
     it is a security boundary, not a convenience knob.
3. **Map the operation to an IAM action via the AWS MCP server, not from memory.** API operation
   names and IAM action names frequently differ (e.g. `CopyObject` needs `s3:GetObject` +
   `s3:PutObject`, not `s3:CopyObject`). Use `mcp__aws__aws___search_documentation` /
   `read_documentation` against the Service Authorization Reference. Before writing the action
   into the `.tf` file, retrieve `mcp__aws__aws___retrieve_skill(skill_name="aws-iam")` and check
   its hallucinated-actions table as a sanity pass.
4. **Pick the area file** per the map above (ask if genuinely ambiguous).
5. **Add the action following this repo's existing comment convention exactly** — every
   `iam-ci-deploy-*.tf` file already does this. The comment must state: (a) which resource or
   mechanism triggers the implicit call, (b) why it isn't obvious from the resource block alone,
   (c) the issue number. Match the voice/format already used in the target file — read a couple
   of the existing comments in that file before writing the new one.
6. **Re-run the failing command for real** against the sandbox after `terraform apply` inside
   `infra/bootstrap` locally. The fix is not done until the *original* command succeeds — a
   plausible-looking action name is not sufficient evidence.
7. **Report the verdict**, and note whether the gap is a one-off (specific to this resource) or
   a category likely to recur elsewhere (e.g. ENI cleanup applies to any future VPC-attached
   Lambda, not just this one).

## Method — Mode B (proactive: preflight before adding a new resource type)

1. Identify the new AWS resource type(s) being introduced.
2. For each, check: the Terraform provider docs/changelog for a documented "required IAM
   permissions" note, and the Service Authorization Reference (via the AWS MCP server) for the
   underlying Create/Read/Update/Delete/Tag/List operations the provider will call across
   plan, apply, refresh, *and* destroy — not just the obvious create call.
3. Specifically check for the two categories that have already bitten this repo twice (#631,
   #640) and are easy to miss because they aren't part of the resource's own CRUD:
   - **Tagging on refresh:** any resource under `default_tags` gets `ListTags`/`TagResource`/
     `UntagResource` called on *every* refresh, not only when tags actually change. Also check
     the negative case — some resource types (e.g. `aws_lambda_permission`,
     `aws_lambda_function_url`) don't expose a `tags` argument at all, so this category
     genuinely doesn't apply; say so in the report rather than silently omitting it.
   - **Dependent-resource cleanup:** resources that spawn child resources with a lifecycle
     outliving the parent (e.g. Lambda ENIs in a VPC survive function deletion) need the
     *cleanup* action on the parent (e.g. `ec2:DeleteNetworkInterface` on the subnet/security
     group), because Terraform tries to force-delete stragglers before deleting the parent.
4. Draft the addition to the relevant area file using the same comment convention as Mode A
   step 5. If step 1's area map genuinely has no single fit (see the map's note above), present
   the candidate files and the ambiguity instead of picking one.
5. State explicitly that this is a **prediction**, not a substitute for verification — mark it
   "needs confirmation via a real sandbox apply/destroy cycle," don't report it as done.

## Method — Mode C (static: prove the policy semantics without an environment)

`aws iam simulate-principal-policy` evaluates the policies **actually attached to the live role**
(identity policies + permissions boundary) against an action/resource pair, and lets you supply
condition-key values with `--context-entries`. It is read-only and costs nothing, so it belongs
in both other modes: as a pre-check before a sandbox cycle, and as the fastest way to answer
"is this deny the condition or the action?" in Mode A step 2b.

It was introduced while verifying #656, where it confirmed the escalation path was closed without
building anything:

```bash
ROLE=$(terraform -chdir=infra/bootstrap output -raw ci_deploy_role_arn)
BOUNDARY=$(terraform -chdir=infra/bootstrap output -raw app_role_boundary_arn)

# The escalation path itself: ci_deploy attaching a policy to its OWN role
# (its name matches ${project}-*). Expect implicitDeny.
aws iam simulate-principal-policy --policy-source-arn "$ROLE" \
  --action-names iam:AttachRolePolicy --resource-arns "$ROLE" \
  --query 'EvaluationResults[].EvalDecision' --output text

# The legitimate path: same action against a role that carries the boundary.
# Expect allowed.
aws iam simulate-principal-policy --policy-source-arn "$ROLE" \
  --action-names iam:AttachRolePolicy \
  --resource-arns arn:aws:iam::<account>:role/<project>-<env>-ecs-task \
  --context-entries ContextKeyName=iam:PermissionsBoundary,ContextKeyValues="$BOUNDARY",ContextKeyType=string \
  --query 'EvaluationResults[].EvalDecision' --output text
```

Reading the results:

- `explicitDeny` — an explicit `Deny` statement matched. This is the only decision that proves a
  guardrail is *in force* rather than merely absent, so use it to verify Deny statements
  (`DenyBoundaryRemoval`, `DenyAssumeRole`, boundary-policy tampering).
- `implicitDeny` — nothing allowed it. Note this is **also** what you get when a required
  condition key is simply missing from `--context-entries`, which is exactly the state a real
  request is in when it doesn't set the boundary. Distinguish the two by re-running with the key
  supplied.
- **Resource-type mismatches silently degrade to `implicitDeny`.** Passing a policy ARN as the
  resource for a role-scoped action (or vice versa) makes a `Deny` you expected to see report as
  implicit. If a Deny you know exists shows up as implicit, re-run with the correct resource type
  before concluding anything.

Limits, so this doesn't get over-trusted: the simulator says what the *policies* decide, never
which API the Terraform provider actually calls (that is Mode A/B's job), and it evaluates the
live attached policies — so `terraform apply` the bootstrap change first, or you are testing the
old policy. It is a complement to the sandbox apply/destroy cycle, never a replacement:
`docs/sandbox.md` and #631 exist precisely because desk-level reasoning missed defects that only a
real run surfaced.

## Conventions / Guardrails

- Every added action needs its own explanatory comment — never a bare action list.
- Never use `Resource: "*"` when a scoped ARN is possible; match the existing per-file pattern
  (name/ARN-scoped where the AWS service supports resource-level ARNs for that action, `"*"`
  only where AWS itself has no resource-level ARN for it — as already documented per file).
- Never widen an existing statement "just in case" — every Mode A/B addition is a minimal,
  concretely-justified action tied to a specific mechanism and issue number.
- This skill never runs `terraform apply`/`destroy` against a non-sandbox account or without
  presenting the diff first. Sandbox real-AWS verification happens in this workspace's own
  bootstrap environment; treat it the same as any other infra change under `docs/sandbox.md`.

## Output Format

```
## ci-deploy IAM gap report
- MODE: A (reactive) | B (proactive)
- TRIGGER: <error text or new-resource description>
- ACTION(S) ADDED: <iam:Action>, ...
- FILE: infra/bootstrap/iam-ci-deploy-<area>.tf  (or: AMBIGUOUS — <candidate files>, needs a human call)
- WHY: <1-2 sentence justification — same content as the comment added>
- CHECKED CATEGORIES: tagging-on-refresh: applies/doesn't apply (why) · dependent-resource cleanup: applies/doesn't apply (why)
- VERIFIED: yes (real terraform apply/destroy succeeded) | pending (prediction only, needs sandbox run)
- ISSUE: #<n> | TBD (pre-issue dry run)
```

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "CI is green, that's enough" | CI's plan/apply never exercises real AWS calls for this role the way a sandbox run does. |
| "Let's add a PowerUserAccess-adjacent wildcard to be safe" | Defeats the point of this role; every action here is justified individually. |
| "The IAM action obviously matches the API operation name" | Frequently wrong (`CopyObject`, `HeadObject`, etc.) — verify against the Service Authorization Reference before writing it. |
| "One fix this round is probably enough" | #631 and #640 each needed multiple real destroy/apply rounds before every gap surfaced — don't stop after the first green step without completing the full apply+destroy cycle. |
