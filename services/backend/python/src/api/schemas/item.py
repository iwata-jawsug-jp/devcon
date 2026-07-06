"""Item schemas."""

from pydantic import BaseModel, ConfigDict, Field


class ItemBase(BaseModel):
    """Fields shared by item create and read models."""

    name: str = Field(max_length=200)
    description: str | None = Field(default=None, max_length=2000)


class ItemCreate(ItemBase):
    """Payload for creating an item."""


class Item(ItemBase):
    """An item as stored and returned by the API."""

    model_config = ConfigDict(from_attributes=True)

    id: int
