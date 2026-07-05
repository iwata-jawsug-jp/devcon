"""Item CRUD endpoints backed by the database repository."""

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from api.auth.dependencies import require_scope
from api.db.models.item import ItemModel
from api.db.session import get_session
from api.repositories.items import ItemRepository
from api.schemas.item import Item, ItemCreate

router = APIRouter(prefix="/api/items", tags=["items"])


def get_repo(session: Annotated[AsyncSession, Depends(get_session)]) -> ItemRepository:
    """Return an :class:`ItemRepository` bound to the request session."""
    return ItemRepository(session)


RepoDep = Annotated[ItemRepository, Depends(get_repo)]

# ``require_scope`` composes ``get_current_user`` internally (nested Depends),
# so declaring just one of these on a route gets both authentication (401)
# and scope-based authorization (403) -- see auth/dependencies.py.
RequireReadScope = Depends(require_scope("api/items.read"))
RequireWriteScope = Depends(require_scope("api/items.write"))


@router.get("", response_model=list[Item], dependencies=[RequireReadScope])
async def list_items(repo: RepoDep) -> list[ItemModel]:
    """Return all items. Requires an authenticated caller with read scope."""
    return list(await repo.list_())


@router.get("/{item_id}", response_model=Item, dependencies=[RequireReadScope])
async def get_item(item_id: int, repo: RepoDep) -> ItemModel:
    """Return a single item by id, or 404 if not found. Requires read scope."""
    item = await repo.get(item_id)
    if item is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Item not found")
    return item


@router.post(
    "",
    response_model=Item,
    status_code=status.HTTP_201_CREATED,
    dependencies=[RequireWriteScope],
)
async def create_item(data: ItemCreate, repo: RepoDep) -> ItemModel:
    """Create a new item and return it. Requires an authenticated caller with write scope."""
    return await repo.create(data)
