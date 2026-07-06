from collections.abc import Callable

from httpx import AsyncClient

AuthedClientFactory = Callable[[list[str] | None], AsyncClient]


async def test_list_items_empty(authed_client: AuthedClientFactory) -> None:
    client = authed_client(None)
    response = await client.get("/api/items")
    assert response.status_code == 200
    assert response.json() == []


async def test_create_item_returns_201(authed_client: AuthedClientFactory) -> None:
    client = authed_client(None)
    payload = {"name": "widget", "description": "a test widget"}
    response = await client.post("/api/items", json=payload)
    assert response.status_code == 201
    body = response.json()
    assert body["id"] >= 1
    assert body["name"] == "widget"
    assert body["description"] == "a test widget"


async def test_get_item_returns_200(authed_client: AuthedClientFactory) -> None:
    client = authed_client(None)
    created = (await client.post("/api/items", json={"name": "gadget"})).json()
    response = await client.get(f"/api/items/{created['id']}")
    assert response.status_code == 200
    assert response.json() == created


async def test_created_item_appears_in_list(authed_client: AuthedClientFactory) -> None:
    client = authed_client(None)
    created = (await client.post("/api/items", json={"name": "listed"})).json()
    listed = (await client.get("/api/items")).json()
    assert any(item["id"] == created["id"] for item in listed)


async def test_get_missing_item_returns_404(authed_client: AuthedClientFactory) -> None:
    client = authed_client(None)
    response = await client.get("/api/items/999999")
    assert response.status_code == 404


async def test_create_item_with_name_over_max_length_returns_422(
    authed_client: AuthedClientFactory,
) -> None:
    client = authed_client(None)
    response = await client.post("/api/items", json={"name": "a" * 201})
    assert response.status_code == 422


async def test_create_item_with_description_over_max_length_returns_422(
    authed_client: AuthedClientFactory,
) -> None:
    client = authed_client(None)
    response = await client.post("/api/items", json={"name": "widget", "description": "a" * 2001})
    assert response.status_code == 422


async def test_create_item_with_name_at_max_length_returns_201(
    authed_client: AuthedClientFactory,
) -> None:
    client = authed_client(None)
    response = await client.post("/api/items", json={"name": "a" * 200})
    assert response.status_code == 201


async def test_list_items_respects_limit_and_offset(
    authed_client: AuthedClientFactory,
) -> None:
    client = authed_client(None)
    created = [
        (await client.post("/api/items", json={"name": f"item-{i}"})).json() for i in range(5)
    ]

    first_page = (await client.get("/api/items", params={"limit": 2, "offset": 0})).json()
    second_page = (await client.get("/api/items", params={"limit": 2, "offset": 2})).json()

    assert [item["id"] for item in first_page] == [created[0]["id"], created[1]["id"]]
    assert [item["id"] for item in second_page] == [created[2]["id"], created[3]["id"]]


async def test_list_items_rejects_limit_over_max(authed_client: AuthedClientFactory) -> None:
    client = authed_client(None)
    response = await client.get("/api/items", params={"limit": 101})
    assert response.status_code == 422
