# Requirements Document

## Introduction

`items` リソースに、軽量な分類用の任意フィールド **`tag`**（文字列・1 個）を追加する。現状 `items`
は `id` / `name` / `description` を持つが、一覧をカテゴリやキーワードで区別する手段がない。本機能は
SDD 試験導入（Epic #66 / #61）の題材として、「モデル → スキーマ → リポジトリ → マイグレーション →
フロント型 → テスト」という既存の最小経路を一周することを目的とする。`description`（既存の任意
文字列フィールド）と同じ実装パターンを踏襲する。

## Boundary Context

- **In scope**: `items` への `tag` フィールド追加（作成・取得・一覧で値が往復すること）、DB
  マイグレーション、OpenAPI からのフロント型再生成、API テスト。
- **Out of scope**: 既存にない `items` の更新（PUT/PATCH）・削除エンドポイントの新設、`tag` による
  検索・絞り込み・集計、フロントの UI 表示（現状 items の UI は未実装のため対象外）、認証・認可。
- **Adjacent expectations**: API 契約（OpenAPI）が変わるため、フロントの生成型 `schema.ts` が
  追従する必要がある（`make gen-types`）。

## Requirements

### Requirement 1: `tag` 付きで item を作成できる
**Objective:** API 利用者として、item 作成時に任意の `tag` を付けたい。そうすれば後から分類の
手がかりにできる。

#### Acceptance Criteria
1. When `POST /api/items` のリクエストボディに `tag` を含めて送る、the API shall その `tag` を
   保存し、レスポンス（201）の item に同じ `tag` を含めて返す。
2. When `POST /api/items` のリクエストボディに `tag` を含めずに送る、the API shall item を正常に
   作成し（201）、`tag` を `null` として扱う。
3. The API shall `tag` を任意（nullable）フィールドとして扱い、未指定でもバリデーションエラーに
   しない。

### Requirement 2: 取得・一覧で `tag` が返る
**Objective:** API 利用者として、item の取得・一覧で `tag` を受け取りたい。そうすれば保存した
分類を参照できる。

#### Acceptance Criteria
1. When `GET /api/items/{item_id}` で `tag` を持つ item を取得する、the API shall その item の
   `tag` を含めて返す。
2. When `GET /api/items` で一覧を取得する、the API shall 各 item の `tag`（無ければ `null`）を
   含めて返す。
3. Where item が `tag` を持たない（未設定）、the API shall 当該フィールドを `null` として返す。

### Requirement 3: スキーマ変更が安全に反映される
**Objective:** 開発者として、`tag` 追加を既存データ・既存ワークフローを壊さずに反映したい。

#### Acceptance Criteria
1. When スキーマを変更する、the 開発者 shall Alembic マイグレーション（`0002_*`）を 1 本追加し、
   既存 head `0001` に連結する（`down_revision = "0001"`）。
2. The マイグレーション shall 既存行に対して `tag` を nullable で追加し、データ移行を不要にする
   （後方互換）。
3. When Pydantic スキーマを変更する、the 開発者 shall `make gen-types` でフロント型 `schema.ts` を
   再生成してコミットする（手書きしない）。
4. The 変更 shall CI（`alembic upgrade head` + pytest）が green になること。

### Requirement 4: テストで往復を保証する
**Objective:** 開発者として、`tag` の作成・取得が回帰しないことをテストで担保したい。

#### Acceptance Criteria
1. The API テスト shall `tag` を付けて作成 → レスポンスとその後の取得で同じ `tag` が返ることを
   検証する。
2. The API テスト shall `tag` 未指定でも作成が 201 で成功し、`tag` が `null` になることを検証する。
