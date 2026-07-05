"""Domain model for authenticated requests (Task 2.1).

See ``.kiro/specs/authn-authz/design.md`` (Data Models > Domain Model): a
non-persistent value object representing the caller resolved from a verified
Cognito access token.
"""

from pydantic import BaseModel


class AuthenticatedUser(BaseModel):
    """The caller resolved from a verified Cognito access token.

    ``sub`` is Cognito's stable user identifier (the JWT ``sub`` claim);
    ``scopes`` is the space-separated ``scope`` claim split into a list
    (e.g. ``["api/items.read"]``).
    """

    sub: str
    scopes: list[str]
