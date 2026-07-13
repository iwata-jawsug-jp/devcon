#!/usr/bin/env python3
"""Validate rendered IAM identity policies against AWS IAM Access Analyzer.

Background (#340, #338): a `data.aws_iam_policy_document` statement can use a
condition key that doesn't exist for the action it's paired with (e.g.
`ecs:task-definition-family`, which isn't a real ECS condition key). A
condition on a key that never appears in the request context can never
match, so the whole statement is silently inert -- `terraform validate` /
tflint (AWS ruleset) / Checkov all pass because the HCL and the rendered JSON
are both syntactically valid; the gap only shows up as a real `AccessDenied`
against actual AWS.

`aws accessanalyzer validate-policy` catches this class of bug (ERROR finding
`INVALID_SERVICE_CONDITION_KEY`) without needing to actually attach or use
the policy. This script extracts every rendered `aws_iam_policy` /
`aws_iam_role_policy` / `aws_iam_user_policy` document from a
`terraform show -json` plan (or state) file and validates each one.

Deliberately scoped to identity/permission policies only -- trust policies
(`assume_role_policy` on `aws_iam_role`) and resource policies (S3 bucket
policies, etc.) are a different Access Analyzer `--policy-type` and validate
differently; broadening this script to cover them is a follow-up, not done
here.

Python standard library only — no third-party dependencies. Requires the
`aws` CLI on PATH with credentials that can call
`accessanalyzer:ValidatePolicy` (a read-only, no-side-effect API call).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

TARGET_RESOURCE_TYPES = {"aws_iam_policy", "aws_iam_role_policy", "aws_iam_user_policy"}


def _iter_module_resources(module: dict) -> list[dict]:
    resources = list(module.get("resources", []))
    for child in module.get("child_modules", []):
        resources.extend(_iter_module_resources(child))
    return resources


def iter_target_resources(plan_or_state: dict):
    """Yield (address, policy_json_or_none) for every managed aws_iam_*policy
    resource in a `terraform show -json` plan or state document."""
    root = plan_or_state.get("planned_values") or plan_or_state.get("values")
    if root is None:
        return
    for resource in _iter_module_resources(root.get("root_module", {})):
        if resource.get("mode") != "managed":
            continue
        if resource.get("type") not in TARGET_RESOURCE_TYPES:
            continue
        policy = resource.get("values", {}).get("policy")
        yield resource.get("address"), policy


def validate_policy_document(
    policy_json: str, policy_type: str = "IDENTITY_POLICY"
) -> list[dict]:
    """Call `aws accessanalyzer validate-policy` and return its findings list."""
    result = subprocess.run(
        [
            "aws",
            "accessanalyzer",
            "validate-policy",
            "--policy-type",
            policy_type,
            "--policy-document",
            policy_json,
            "--output",
            "json",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip() or "aws accessanalyzer validate-policy failed"
        )
    return json.loads(result.stdout).get("findings", [])


def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "plan_json",
        type=Path,
        help="Path to a `terraform show -json` plan or state file.",
    )
    parser.add_argument(
        "--policy-type",
        default="IDENTITY_POLICY",
        choices=["IDENTITY_POLICY", "RESOURCE_POLICY", "SERVICE_CONTROL_POLICY"],
    )
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    data = json.loads(args.plan_json.read_text())
    targets = list(iter_target_resources(data))

    if not targets:
        print(
            "No aws_iam_policy / aws_iam_role_policy / aws_iam_user_policy resources found."
        )
        return 0

    had_error = False
    for address, policy_json in targets:
        if policy_json is None:
            print(f"skip: {address} -- policy value not known until apply")
            continue
        try:
            findings = validate_policy_document(policy_json, args.policy_type)
        except RuntimeError as exc:
            print(f"error: {address}: {exc}", file=sys.stderr)
            had_error = True
            continue

        errors = [f for f in findings if f.get("findingType") == "ERROR"]
        if errors:
            had_error = True
            print(
                f"error: {address} -- {len(errors)} policy validation error(s):",
                file=sys.stderr,
            )
            for finding in errors:
                print(
                    f"  - [{finding.get('issueCode')}] {finding.get('findingDetails')}",
                    file=sys.stderr,
                )
        else:
            print(f"OK: {address}")

    return 1 if had_error else 0


if __name__ == "__main__":
    sys.exit(main())
