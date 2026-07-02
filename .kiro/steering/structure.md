# Project Structure

## Organization Philosophy

トップは**サービス別**（`services/backend/python` / `services/frontend` / `infra`）のモノレポ。
`backend/` は開発言語ごとにサブフォルダを分ける（将来 Python 以外を追加する場合は
`services/backend/<言語>/` を並置）。各サービス内は**レイヤード**（backend は
router → repository → model、frontend は view/component → api client → 生成型）。
規約・ルールの「正」は `docs/` に一本化し、`CLAUDE.md` 群はそれを参照する薄い抽出に留める。

## Directory Patterns

### バックエンド API

**Location**: `services/backend/python/src/api/`
**Purpose**: FastAPI アプリ。レイヤごとにディレクトリ分割。
**Example**:

- `routers/` — エンドポイント（`items.py` は `/api/items` の GET/POST）
- `schemas/` — Pydantic の request/response（`ItemBase` → `ItemCreate` / `Item`）
- `repositories/` — データアクセス（`ItemRepository`、raw SQL 禁止）
- `db/models/` — SQLAlchemy モデル（`ItemModel`、`__init__.py` で re-export → Alembic が拾う）
- `alembic/versions/` — マイグレーション（`<rev>_<slug>.py`、現 head = `0001`）

### フロントエンド Web

**Location**: `services/frontend/src/`
**Purpose**: Vite + Vue 3 SPA。
**Example**: `views/` / `components/` / `api/`（`client.ts` ＝ API クライアント、
`schema.ts` ＝ **OpenAPI から自動生成・手書き禁止**）

### インフラ / ドキュメント

**Location**: `infra/`（Terraform 2 層）/ `docs/`（規約の正）/ `.kiro/`（SDD 成果物）

## Naming Conventions

- **ブランチ**: 機能 `feat/<slug>` / 修正 `fix/<slug>`。1 issue = 1 ブランチ = 1 focused PR。
- **マイグレーション**: `<連番4桁>_<slug>.py`（例 `0002_add_tag_to_items.py`、`down_revision` で連結）。
- **API 由来の型**: 手書きせず `make gen-types` で生成。

## Code Organization Principles

- **API 契約は OpenAPI が正**。Pydantic を変えたら `make gen-types` で web 型を再生成してコミット。
- **スキーマ変更は必ず Alembic**。モデル変更だけで DB を直接いじらない。
- **依存方向**: router → repository → model（逆流させない）。テストは `repositories`/router を
  `Depends` override で差し替え、in-memory SQLite はメタデータからテーブル生成。
- **秘密は持ち込まない**: `.env`/`*.tfvars`/鍵は git-ignore、`*.example` のみコミット。

---

_Document patterns, not file trees. New files following patterns shouldn't require updates_
