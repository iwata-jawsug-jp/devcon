"""align items primary key constraint name with naming convention

Revision ID: 81d9aaa3abff
Revises: dc70f2cc0640
Create Date: 2026-07-27 11:12:59.383521

"""

from collections.abc import Sequence

from alembic import op

# revision identifiers, used by Alembic.
__all__ = ["revision", "down_revision", "branch_labels", "depends_on"]

revision: str = "81d9aaa3abff"
down_revision: str | None = "dc70f2cc0640"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # Postgres auto-named this "items_pkey" (its default "<table>_pkey" convention) on any
    # DB that ran migration 0001 before db/base.py's Base.metadata declared a
    # naming_convention. Guarded rename (not a bare ALTER TABLE): env.py passes
    # target_metadata to Alembic, and empirically that makes op.create_table's own DDL
    # emission honor the *current* naming_convention too -- so a fresh `upgrade head` (CI,
    # a new clone) creates the table as "pk_items" directly via migration 0001 and never
    # has an "items_pkey" to rename. Without the guard this migration would fail with
    # "constraint items_pkey does not exist" on exactly those fresh chains.
    op.execute(
        """
        DO $$
        BEGIN
            IF EXISTS (
                SELECT 1 FROM pg_constraint
                WHERE conrelid = 'items'::regclass AND conname = 'items_pkey'
            ) THEN
                ALTER TABLE items RENAME CONSTRAINT items_pkey TO pk_items;
            END IF;
        END $$;
        """
    )


def downgrade() -> None:
    op.execute(
        """
        DO $$
        BEGIN
            IF EXISTS (
                SELECT 1 FROM pg_constraint
                WHERE conrelid = 'items'::regclass AND conname = 'pk_items'
            ) THEN
                ALTER TABLE items RENAME CONSTRAINT pk_items TO items_pkey;
            END IF;
        END $$;
        """
    )
