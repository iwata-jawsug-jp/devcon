"""Request-scoped database session dependency."""

from collections.abc import AsyncIterator

from sqlalchemy.ext.asyncio import AsyncSession

from api.db.engine import AsyncSessionLocal


async def get_session() -> AsyncIterator[AsyncSession]:
    """Yield an :class:`AsyncSession`, closing it when the request ends."""
    async with AsyncSessionLocal() as session:
        yield session
