#!/usr/bin/env python3
"""Check that infra/auth.tf's Cognito resource-server scopes match the
frontend's OIDC login scope request list.

Background (#438): a scope added to the Cognito resource server and enforced
via the backend's `require_scope` can still be missing from the frontend's
login-time scope request (`oidcConfig.ts`). That gap only surfaces as a 403
against a real Cognito-issued token — no unit/integration test catches it,
because they don't go through a real Hosted UI login. This script performs a
static, no-login-required cross-check instead.

Python standard library only — no third-party dependencies.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_AUTH_TF = REPO_ROOT / "infra" / "auth.tf"
DEFAULT_OIDC_CONFIG = (
    REPO_ROOT / "services" / "frontend" / "src" / "auth" / "oidcConfig.ts"
)

# Standard OIDC scopes that aren't tied to any resource server, so they're
# expected in oidcConfig.ts's scope string without a matching auth.tf entry.
STANDARD_OIDC_SCOPES = {
    "openid",
    "email",
    "phone",
    "profile",
    "aws.cognito.signin.user.admin",
}

_RESOURCE_SERVER_RE = re.compile(
    r'resource\s+"aws_cognito_resource_server"\s+"[^"]+"\s*\{', re.MULTILINE
)
_IDENTIFIER_RE = re.compile(r'identifier\s*=\s*"([^"]+)"')
_SCOPE_NAME_RE = re.compile(r'scope_name\s*=\s*"([^"]+)"')
_OIDC_SCOPE_CONST_RE = re.compile(r"""const\s+scope\s*=\s*['"]([^'"]*)['"]""")


def _extract_block(text: str, open_brace_index: int) -> str:
    """Return the `{ ... }` block body starting at `open_brace_index` (which
    must point at the opening `{`), matching braces so nested `scope { ... }`
    blocks don't confuse the boundary."""
    depth = 0
    for i in range(open_brace_index, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_brace_index + 1 : i]
    raise ValueError("unbalanced braces in Terraform resource block")


def parse_resource_server_scopes(auth_tf_text: str) -> set[str]:
    """Return the set of `<identifier>/<scope_name>` scopes every
    `aws_cognito_resource_server` in `auth_tf_text` defines."""
    scopes: set[str] = set()
    for match in _RESOURCE_SERVER_RE.finditer(auth_tf_text):
        block = _extract_block(auth_tf_text, match.end() - 1)
        identifier_match = _IDENTIFIER_RE.search(block)
        if not identifier_match:
            raise ValueError("aws_cognito_resource_server block has no identifier")
        identifier = identifier_match.group(1)
        for scope_name in _SCOPE_NAME_RE.findall(block):
            scopes.add(f"{identifier}/{scope_name}")
    return scopes


def parse_oidc_requested_scopes(oidc_config_text: str) -> set[str]:
    """Return the whitespace-separated scopes in oidcConfig.ts's `scope` constant."""
    match = _OIDC_SCOPE_CONST_RE.search(oidc_config_text)
    if not match:
        raise ValueError("could not find `const scope = '...'` in oidcConfig.ts")
    return set(match.group(1).split())


def check(auth_tf_text: str, oidc_config_text: str) -> list[str]:
    """Return a list of human-readable problems; empty means the two files agree."""
    defined = parse_resource_server_scopes(auth_tf_text)
    requested = parse_oidc_requested_scopes(oidc_config_text)

    missing = sorted(defined - requested)
    unknown = sorted(requested - defined - STANDARD_OIDC_SCOPES)

    problems = []
    if missing:
        problems.append(
            "auth.tf defines these scopes but oidcConfig.ts's login scope list doesn't "
            f"request them: {', '.join(missing)}"
        )
    if unknown:
        problems.append(
            "oidcConfig.ts requests these scopes but no auth.tf resource server defines "
            f"them: {', '.join(unknown)}"
        )
    return problems


def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--auth-tf", type=Path, default=DEFAULT_AUTH_TF)
    parser.add_argument("--oidc-config", type=Path, default=DEFAULT_OIDC_CONFIG)
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    problems = check(args.auth_tf.read_text(), args.oidc_config.read_text())
    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        print(
            "\nSee #438: when adding/removing an OAuth scope, update infra/auth.tf's "
            "resource server, the backend's require_scope, AND "
            "services/frontend/src/auth/oidcConfig.ts's scope constant together.",
            file=sys.stderr,
        )
        return 1
    print(f"OK: {args.auth_tf} and {args.oidc_config} scopes match")
    return 0


if __name__ == "__main__":
    sys.exit(main())
