from httpx import AsyncClient


async def test_greeting_default(client: AsyncClient) -> None:
    response = await client.get("/api/greeting")
    assert response.status_code == 200
    assert response.json() == {"message": "Hello, world!", "name": "world"}


async def test_greeting_with_name(client: AsyncClient) -> None:
    response = await client.get("/api/greeting", params={"name": "JAWS-UG"})
    assert response.status_code == 200
    assert response.json() == {"message": "Hello, JAWS-UG!", "name": "JAWS-UG"}


async def test_greeting_name_too_long_returns_422(client: AsyncClient) -> None:
    response = await client.get("/api/greeting", params={"name": "x" * 51})
    assert response.status_code == 422
