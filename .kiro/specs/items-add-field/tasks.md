# Implementation Plan — items に `tag` フィールドを追加

> このタスク群は 1 つの focused PR（`feat/items-add-tag` 等）で完結する想定。`docs/issues.md` の
> 「1 issue → 1 PR・CI green 確認」に接続する。各タスクは上から順に実施（DB → 契約 → 型 → テスト）。

- [ ] 1. バックエンドのモデル・スキーマ・リポジトリに `tag` を追加
  - `services/api/src/api/db/models/item.py`: `ItemModel` に `tag: Mapped[str | None] = mapped_column(nullable=True)` を追加
  - `services/api/src/api/schemas/item.py`: `ItemBase` に `tag: str | None = None` を追加（`ItemCreate` / `Item` に波及）
  - `services/api/src/api/repositories/items.py`: `create()` の `ItemModel(...)` に `tag=data.tag` を追加
  - 完了条件: api がローカル起動し、`tag` 付き POST のレスポンスに `tag` が返る
  - _Requirements: 1.1, 1.2, 1.3, 2.1, 2.2, 2.3_

- [ ] 2. Alembic マイグレーション `0002_add_tag_to_items` を追加
  - `make makemigration m="add tag to items"` で生成 → `revision="0002"` / `down_revision="0001"` を確認
  - `upgrade()` が `add_column("items", Column("tag", String(), nullable=True))`、`downgrade()` が `drop_column` であることを確認
  - `make migrate` でローカル適用が通る
  - 完了条件: `alembic upgrade head` がエラーなく適用され、既存行が壊れない（後方互換）
  - _Requirements: 3.1, 3.2_
  - _Depends: 1_

- [ ] 3. フロント生成型を再生成
  - `make gen-types` を実行し、`services/web/src/api/schema.ts` の `Item` / `ItemCreate` に `tag` が入ることを確認
  - 生成物をコミット（手編集しない）
  - 完了条件: `schema.ts` に `tag?: string | null` が反映され、`vue-tsc` が通る
  - _Requirements: 3.3_
  - _Depends: 1_

- [ ] 4. API テストを追加
  - `services/api/tests/test_items.py` に: ①`tag` 付き作成→201・レスポンスに `tag`、②その後の取得で同じ `tag`、③`tag` 未指定→201・`null`、④一覧に `tag` を含む、のアサーションを追加
  - 完了条件: `make test`（pytest）がローカルで green
  - _Requirements: 4.1, 4.2, 2.2_
  - _Depends: 1_

- [ ] 5. CI 相当でのグリーン確認と PR
  - ローカルで CI と同じコマンドをミラー（`make lint` / `make test`、必要に応じ `make security`）
  - PR を作成し（本文に `Closes #<実装 issue>`）、CI（`alembic upgrade head` + pytest、web 型チェック）が**実際に green**になるまで確認
  - 完了条件: CI の該当ジョブが緑。`make gen-types` のコミット漏れがないこと
  - _Requirements: 3.4_
  - _Depends: 1, 2, 3, 4_

---

## メモ（実装フェーズへの引き継ぎ）

- router（`routers/items.py`）は変更不要（`ItemCreate`/`Item` 経由で透過）。
- `description` の実装が完全な手本。差分は「`description` と書いてある所に `tag` も足す」だけ。
- 本 PoC（#61）はこの tasks.md の生成までがスコープ。実際の実装 PR 化は採否判断後に別 issue で。
