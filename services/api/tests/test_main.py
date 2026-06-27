from api.main import greet


def test_greet_default() -> None:
    assert greet() == "Hello, world!"


def test_greet_name() -> None:
    assert greet("devcon") == "Hello, devcon!"
