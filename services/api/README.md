# api (Python service)

Python application service, managed with [uv](https://docs.astral.sh/uv/).

```bash
uv sync            # install deps (incl. dev group)
uv run api         # run the CLI entry point
uv run pytest      # tests
uv run ruff check . && uv run mypy   # lint + type check
```
