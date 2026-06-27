"""Repository encapsulating item persistence."""

from collections.abc import Sequence

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.db.models.item import ItemModel
from api.schemas.item import ItemCreate


class ItemRepository:
    """Async data-access layer for :class:`ItemModel`."""

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def list_(self) -> Sequence[ItemModel]:
        """Return all items."""
        result = await self._session.execute(select(ItemModel))
        return result.scalars().all()

    async def get(self, item_id: int) -> ItemModel | None:
        """Return a single item by id, or ``None`` if it does not exist."""
        return await self._session.get(ItemModel, item_id)

    async def create(self, data: ItemCreate) -> ItemModel:
        """Persist a new item and return it."""
        item = ItemModel(name=data.name, description=data.description)
        self._session.add(item)
        await self._session.commit()
        await self._session.refresh(item)
        return item
