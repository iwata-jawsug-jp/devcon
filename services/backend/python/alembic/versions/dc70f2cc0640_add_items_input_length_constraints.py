"""add items input length constraints

Revision ID: dc70f2cc0640
Revises: 0001
Create Date: 2026-07-06 10:13:35.925009

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
__all__ = ["revision", "down_revision", "branch_labels", "depends_on"]

revision: str = "dc70f2cc0640"
down_revision: str | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # Autogenerate found no diff here: alembic's default compare_type=False
    # doesn't detect VARCHAR length changes, so these are hand-written (#305).
    op.alter_column("items", "name", type_=sa.String(200), existing_nullable=False)
    op.alter_column("items", "description", type_=sa.String(2000), existing_nullable=True)


def downgrade() -> None:
    op.alter_column("items", "name", type_=sa.String(), existing_nullable=False)
    op.alter_column("items", "description", type_=sa.String(), existing_nullable=True)
