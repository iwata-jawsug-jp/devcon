"""Item CRUD endpoints backed by the database repository."""

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from api.db.models.item import ItemModel
from api.db.session import get_session
from api.repositories.items import ItemRepository
from api.schemas.item import Item, ItemCreate

router = APIRouter(prefix="/api/items", tags=["items"])


def get_repo(session: Annotated[AsyncSession, Depends(get_session)]) -> ItemRepository:
    """Return an :class:`ItemRepository` bound to the request session."""
    return ItemRepository(session)


RepoDep = Annotated[ItemRepository, Depends(get_repo)]


@router.get("", response_model=list[Item])
async def list_items(repo: RepoDep) -> list[ItemModel]:
    """Return all items."""
    return list(await repo.list_())


@router.get("/{item_id}", response_model=Item)
async def get_item(item_id: int, repo: RepoDep) -> ItemModel:
    """Return a single item by id, or 404 if not found."""
    item = await repo.get(item_id)
    if item is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Item not found")
    return item


@router.post("", response_model=Item, status_code=status.HTTP_201_CREATED)
async def create_item(data: ItemCreate, repo: RepoDep) -> ItemModel:
    """Create a new item and return it."""
    return await repo.create(data)
