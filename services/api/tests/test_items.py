from fastapi.testclient import TestClient

from api.main import app

client = TestClient(app)


def test_list_items_returns_list() -> None:
    response = client.get("/api/items")
    assert response.status_code == 200
    assert isinstance(response.json(), list)


def test_create_and_get_item() -> None:
    payload = {"name": "widget", "description": "a test widget"}
    created = client.post("/api/items", json=payload)
    assert created.status_code == 201
    body = created.json()
    assert body["id"] >= 1
    assert body["name"] == "widget"
    assert body["description"] == "a test widget"

    fetched = client.get(f"/api/items/{body['id']}")
    assert fetched.status_code == 200
    assert fetched.json() == body


def test_created_item_appears_in_list() -> None:
    created = client.post("/api/items", json={"name": "listed"}).json()
    listed = client.get("/api/items").json()
    assert any(item["id"] == created["id"] for item in listed)


def test_get_missing_item_returns_404() -> None:
    response = client.get("/api/items/999999")
    assert response.status_code == 404
