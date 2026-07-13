from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import check_oauth_scopes  # noqa: E402

AUTH_TF = """
resource "aws_cognito_resource_server" "api" {
  identifier   = "api"
  name         = "api"
  user_pool_id = aws_cognito_user_pool.users.id

  scope {
    scope_name        = "items.read"
    scope_description = "Read access to items"
  }

  scope {
    scope_name        = "items.write"
    scope_description = "Write access to items"
  }
}
"""


def _oidc(scope_value: str) -> str:
    return f"const scope = '{scope_value}';\n"


class ParseResourceServerScopesTests(unittest.TestCase):
    def test_extracts_identifier_scope_pairs(self):
        scopes = check_oauth_scopes.parse_resource_server_scopes(AUTH_TF)
        self.assertEqual(scopes, {"api/items.read", "api/items.write"})

    def test_multiple_resource_servers(self):
        text = (
            AUTH_TF
            + '\nresource "aws_cognito_resource_server" "orders" {\n  identifier = "orders"\n\n  scope {\n    scope_name = "read"\n  }\n}\n'
        )
        scopes = check_oauth_scopes.parse_resource_server_scopes(text)
        self.assertEqual(scopes, {"api/items.read", "api/items.write", "orders/read"})

    def test_no_resource_server_returns_empty(self):
        self.assertEqual(
            check_oauth_scopes.parse_resource_server_scopes("# nothing here"), set()
        )


class ParseOidcRequestedScopesTests(unittest.TestCase):
    def test_splits_whitespace_separated_scopes(self):
        scopes = check_oauth_scopes.parse_oidc_requested_scopes(
            _oidc("openid api/items.read api/items.write")
        )
        self.assertEqual(scopes, {"openid", "api/items.read", "api/items.write"})

    def test_missing_scope_constant_raises(self):
        with self.assertRaises(ValueError):
            check_oauth_scopes.parse_oidc_requested_scopes(
                "export const somethingElse = 1;"
            )


class CheckTests(unittest.TestCase):
    def test_matching_scopes_has_no_problems(self):
        problems = check_oauth_scopes.check(
            AUTH_TF, _oidc("openid api/items.read api/items.write")
        )
        self.assertEqual(problems, [])

    def test_missing_frontend_scope_is_reported(self):
        problems = check_oauth_scopes.check(AUTH_TF, _oidc("openid api/items.read"))
        self.assertEqual(len(problems), 1)
        self.assertIn("api/items.write", problems[0])

    def test_unknown_frontend_scope_is_reported(self):
        problems = check_oauth_scopes.check(
            AUTH_TF, _oidc("openid api/items.read api/items.write api/orders.read")
        )
        self.assertEqual(len(problems), 1)
        self.assertIn("api/orders.read", problems[0])

    def test_standard_oidc_scopes_are_not_flagged_as_unknown(self):
        problems = check_oauth_scopes.check(
            AUTH_TF, _oidc("openid email profile api/items.read api/items.write")
        )
        self.assertEqual(problems, [])


if __name__ == "__main__":
    unittest.main()
