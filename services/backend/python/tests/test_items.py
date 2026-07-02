from httpx import AsyncClient


async def test_list_items_empty(client: AsyncClient) -> None:
    response = await client.get("/api/items")
    assert response.status_code == 200
    assert response.json() == []


async def test_create_item_returns_201(client: AsyncClient) -> None:
    payload = {"name": "widget", "description": "a test widget"}
    response = await client.post("/api/items", json=payload)
    assert response.status_code == 201
    body = response.json()
    assert body["id"] >= 1
    assert body["name"] == "widget"
    assert body["description"] == "a test widget"


async def test_get_item_returns_200(client: AsyncClient) -> None:
    created = (await client.post("/api/items", json={"name": "gadget"})).json()
    response = await client.get(f"/api/items/{created['id']}")
    assert response.status_code == 200
    assert response.json() == created


async def test_created_item_appears_in_list(client: AsyncClient) -> None:
    created = (await client.post("/api/items", json={"name": "listed"})).json()
    listed = (await client.get("/api/items")).json()
    assert any(item["id"] == created["id"] for item in listed)


async def test_get_missing_item_returns_404(client: AsyncClient) -> None:
    response = await client.get("/api/items/999999")
    assert response.status_code == 404
