"""Item schemas."""

from pydantic import BaseModel, ConfigDict


class ItemBase(BaseModel):
    """Fields shared by item create and read models."""

    name: str
    description: str | None = None


class ItemCreate(ItemBase):
    """Payload for creating an item."""


class Item(ItemBase):
    """An item as stored and returned by the API."""

    model_config = ConfigDict(from_attributes=True)

    id: int
