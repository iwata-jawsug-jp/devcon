"""Auth/authz behavior for the items endpoints (Task 3.1).

Covers Requirement 1.4 (health stays open, tested elsewhere), 2.1-2.3: GET
(list/single) requires ``api/items.read``, POST requires ``api/items.write``,
and both compose ``get_current_user`` so an unauthenticated caller gets 401
before scope is even considered.
"""

from collections.abc import Callable

from httpx import AsyncClient

AuthedClientFactory = Callable[[list[str] | None], AsyncClient]


# -- Unauthenticated: 401 (Requirement 1.1/1.4 via 2.x endpoints) -----------


async def test_list_items_unauthenticated_returns_401(client: AsyncClient) -> None:
    response = await client.get("/api/items")
    assert response.status_code == 401


async def test_get_item_unauthenticated_returns_401(client: AsyncClient) -> None:
    response = await client.get("/api/items/1")
    assert response.status_code == 401


async def test_create_item_unauthenticated_returns_401(client: AsyncClient) -> None:
    response = await client.post("/api/items", json={"name": "widget"})
    assert response.status_code == 401


# -- Authenticated without read scope: 403 on GET (Requirement 2.1 analogue) --


async def test_list_items_without_read_scope_returns_403(
    authed_client: AuthedClientFactory,
) -> None:
    client = authed_client(["api/items.write"])
    response = await client.get("/api/items")
    assert response.status_code == 403


async def test_get_item_without_read_scope_returns_403(
    authed_client: AuthedClientFactory,
) -> None:
    client = authed_client(["api/items.write"])
    response = await client.get("/api/items/1")
    assert response.status_code == 403


# -- Authenticated without write scope: 403 on POST (Requirement 2.1) -------


async def test_create_item_without_write_scope_returns_403(
    authed_client: AuthedClientFactory,
) -> None:
    client = authed_client(["api/items.read"])
    response = await client.post("/api/items", json={"name": "widget"})
    assert response.status_code == 403


# -- Authenticated with write scope: 201 (Requirement 2.2) ------------------


async def test_create_item_with_write_scope_returns_201(
    authed_client: AuthedClientFactory,
) -> None:
    client = authed_client(["api/items.write"])
    response = await client.post("/api/items", json={"name": "widget"})
    assert response.status_code == 201


# -- Authenticated with read scope only: 200 (Requirement 2.3 normal path) --
#
# Mirrors test_list_items_without_read_scope_returns_403 /
# test_get_item_without_read_scope_returns_403 (write-only scope -> 403) from
# the opposite direction: a caller holding *only* ``api/items.read`` (no
# write scope) must still succeed on the read endpoints. The pre-existing
# test_items.py suite only exercises GET success via authed_client(None),
# which grants both read *and* write scope, so it never isolates "read scope
# alone is sufficient" as a standalone, minimal-privilege case.


async def test_list_items_with_read_scope_returns_200(
    authed_client: AuthedClientFactory,
) -> None:
    client = authed_client(["api/items.read"])
    response = await client.get("/api/items")
    assert response.status_code == 200
    assert response.json() == []


async def test_get_item_with_read_scope_returns_200(
    authed_client: AuthedClientFactory,
) -> None:
    full_client = authed_client(["api/items.read", "api/items.write"])
    created = (await full_client.post("/api/items", json={"name": "widget"})).json()

    read_only_client = authed_client(["api/items.read"])
    response = await read_only_client.get(f"/api/items/{created['id']}")
    assert response.status_code == 200
    assert response.json() == created
