"""Greeting schemas."""

from pydantic import BaseModel


class Greeting(BaseModel):
    """A greeting message for the given name."""

    message: str
    name: str
