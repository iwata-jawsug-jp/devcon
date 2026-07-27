"""Request-scoped database session dependency."""

from collections.abc import AsyncIterator

from sqlalchemy.ext.asyncio import AsyncSession

from api.db.engine import AsyncSessionLocal


async def get_session() -> AsyncIterator[AsyncSession]:
    """Yield an :class:`AsyncSession`, committing once the request succeeds.

    Unit-of-work boundary: repositories only ``flush()``, so a handler that
    calls more than one repository method still commits atomically as a
    single transaction here. Rolls back (and re-raises) on any exception,
    including one raised by the route handler itself.
    """
    async with AsyncSessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
