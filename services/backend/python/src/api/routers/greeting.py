"""Greeting endpoints."""

from typing import Annotated

from fastapi import APIRouter, Query

from api.schemas.greeting import Greeting

router = APIRouter(prefix="/api", tags=["greeting"])


@router.get("/greeting", response_model=Greeting)
async def greeting(name: Annotated[str, Query(max_length=50)] = "world") -> Greeting:
    """Return a greeting for ``name``."""
    return Greeting(message=f"Hello, {name}!", name=name)
