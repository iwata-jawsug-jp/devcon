"""Item ORM model."""

from sqlalchemy.orm import Mapped, mapped_column

from api.db.base import Base


class ItemModel(Base):
    """Persisted item row."""

    __tablename__ = "items"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column()
    description: Mapped[str | None] = mapped_column(nullable=True)
