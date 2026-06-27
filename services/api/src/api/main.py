"""Application entry point."""


def greet(name: str = "world") -> str:
    """Return a greeting message."""
    return f"Hello, {name}!"


def main() -> None:
    """CLI entry point."""
    print(greet())


if __name__ == "__main__":
    main()
