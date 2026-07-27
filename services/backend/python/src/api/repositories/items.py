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

    async def list_(self, limit: int = 50, offset: int = 0) -> Sequence[ItemModel]:
        """Return a page of items, ordered by id."""
        result = await self._session.execute(
            select(ItemModel).order_by(ItemModel.id).limit(limit).offset(offset)
        )
        return result.scalars().all()

    async def get(self, item_id: int) -> ItemModel | None:
        """Return a single item by id, or ``None`` if it does not exist."""
        return await self._session.get(ItemModel, item_id)

    async def create(self, data: ItemCreate) -> ItemModel:
        """Persist a new item and return it.

        Flushes (not commits) so callers stay composable within one request's
        transaction; ``get_session`` commits once at the request boundary
        (unit of work) -- see ``db/session.py``. A Postgres INSERT populates
        generated columns (``id``, ``created_at``, ``updated_at``) via
        ``RETURNING`` on flush, so no extra ``refresh()`` round trip is needed.
        """
        item = ItemModel(name=data.name, description=data.description)
        self._session.add(item)
        await self._session.flush()
        return item
