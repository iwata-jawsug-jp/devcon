"""Item CRUD endpoints backed by an in-memory store."""

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status

from api.schemas.item import Item, ItemCreate

router = APIRouter(prefix="/api/items", tags=["items"])


class ItemStore:
    """A simple in-memory item store."""

    def __init__(self) -> None:
        self._items: dict[int, Item] = {}
        self._next_id = 1

    def list(self) -> list[Item]:
        return list(self._items.values())

    def get(self, item_id: int) -> Item | None:
        return self._items.get(item_id)

    def create(self, data: ItemCreate) -> Item:
        item = Item(id=self._next_id, **data.model_dump())
        self._items[item.id] = item
        self._next_id += 1
        return item


_store = ItemStore()


def get_store() -> ItemStore:
    """Return the shared in-memory item store."""
    return _store


StoreDep = Annotated[ItemStore, Depends(get_store)]


@router.get("", response_model=list[Item])
async def list_items(store: StoreDep) -> list[Item]:
    """Return all items."""
    return store.list()


@router.get("/{item_id}", response_model=Item)
async def get_item(item_id: int, store: StoreDep) -> Item:
    """Return a single item by id, or 404 if not found."""
    item = store.get(item_id)
    if item is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Item not found")
    return item


@router.post("", response_model=Item, status_code=status.HTTP_201_CREATED)
async def create_item(data: ItemCreate, store: StoreDep) -> Item:
    """Create a new item and return it."""
    return store.create(data)
