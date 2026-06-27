# アプリケーション開発ガイド

`services/api`（バックエンド）と `services/web`（フロントエンド）の開発手順・構造・規約。
全体のアーキテクチャは [`../CLAUDE.md`](../CLAUDE.md) を参照。

## アーキテクチャ概要

```
ブラウザ ──/api/*──▶ web (Vite:5173)  ──proxy──▶  api (uvicorn:8000)
            静的 SPA(Vue3)                         REST API(FastAPI)
```

- `web` は静的 SPA、`api` はステートレスな JSON API。別プロセス。
- ブラウザは相対パス `/api/*` で API を呼ぶ。**開発時**は Vite が `/api/*` を
  uvicorn(:8000) にプロキシ（CORS 不要）。**本番**は CloudFront が `/api/*` を api
  オリジンへルーティング。
- ブラウザが AWS を直接叩くことはない。データは必ず `api` を経由する。
- API 契約は FastAPI の OpenAPI（`/openapi.json`）が単一の正。フロントの型はそこから
  **生成**する（`make gen-types`）。型を二重に手書きしない。

## ローカル起動

```bash
make dev    # api(:8000) と web(:5173) を同時起動
```

- アプリ: http://localhost:5173
- API ドキュメント（Swagger UI）: http://localhost:8000/docs
- 個別起動: `make api-dev` / `make web-dev`

---

## バックエンド: `services/api`（FastAPI）

### 構造

```
services/api/
├── pyproject.toml            # uv 管理。依存: fastapi / uvicorn / pydantic-settings
├── Dockerfile                # 本番イメージ（CD で ECR に push）
├── .env.example              # API_ プレフィックスの環境変数テンプレート
└── src/api/
    ├── main.py               # FastAPI app（api.main:app）。ルーターを include
    ├── config.py             # pydantic-settings の Settings / get_settings()
    ├── routers/              # APIRouter（/api 配下）
    │   ├── health.py         #   GET /api/health
    │   └── items.py          #   GET/POST /api/items, GET /api/items/{id}
    └── schemas/              # Pydantic モデル（リクエスト/レスポンス）
        ├── health.py         #   HealthStatus
        └── item.py           #   ItemBase / ItemCreate / Item
tests/                        # TestClient ベース（test_health.py, test_items.py）
```

### 開発フロー

```bash
cd services/api
uv sync                                  # 依存同期（uv 管理。pip/python を直接使わない）
uv run uvicorn api.main:app --reload     # 開発サーバ（:8000）
uv run pytest                            # テスト
uv run ruff check . && uv run mypy       # lint + 型チェック（strict）
```

### 規約

- **非同期ハンドラ**（`async def`）で書く。
- レスポンス/リクエストは **Pydantic モデルで検証**する（生 dict を返さない）。
  ルーターには `response_model=` を指定する。
- 依存は `Depends` で注入する（例: `items.py` の `ItemStore` を `Depends(get_store)`）。
- 設定は `pydantic-settings` の `Settings` 経由。環境変数は **`API_` プレフィックス**
  （`API_ENVIRONMENT`, `API_APP_NAME`）。秘密情報はコミットせず `.env`（git-ignored）に置く。
- ルートは `/api` プレフィックス配下に置く（フロントの `/api/*` 呼び出しと一致させる）。
- ruff（line length 100 / `py312`）、mypy strict、型ヒント必須。

### エンドポイントを追加するには

1. `src/api/schemas/` に Pydantic モデルを追加。
2. `src/api/routers/` に `APIRouter` を作り、`async` ハンドラを `response_model` 付きで定義。
3. `src/api/main.py` で `app.include_router(...)`。
4. `tests/` に `TestClient` のテストを追加。
5. フロントで使うなら `make gen-types` で型を再生成（後述）。

### データベース（SQLAlchemy async + Alembic）

`api` は PostgreSQL に永続化する。ローカルは docker-compose の Postgres、本番は RDS。

```
services/api/
├── docker-compose 用 DB は リポジトリルートの docker-compose.yml（postgres:16）
├── src/api/db/
│   ├── base.py            # DeclarativeBase（Base）
│   ├── engine.py          # async engine + AsyncSessionLocal
│   ├── session.py         # get_session()（Depends で AsyncSession を注入）
│   └── models/item.py     # ORM モデル（Mapped[...] 型付き、ItemModel）
├── src/api/repositories/  # データアクセス（ItemRepository）
└── alembic/               # マイグレーション（env.py は非同期, versions/）
```

開発フロー:

```bash
make db-up                       # ローカル Postgres 起動（docker-compose）
make migrate                     # alembic upgrade head（スキーマ適用）
make makemigration m="add foo"   # モデル変更から差分マイグレーションを自動生成
cd services/api && uv run pytest # テスト（後述のとおり既定は SQLite）
```

規約:
- **ルーターは生 SQL を書かない**。`Depends(get_session)` で `AsyncSession` を受け取り、
  `repositories/` 経由でアクセスする。
- ORM モデルは `Mapped[...]` で型付け（mypy strict 準拠）。Pydantic スキーマ（API I/O）と
  ORM モデルは分離し、レスポンス用 Pydantic は `from_attributes=True`。
- **スキーマ変更は必ず Alembic マイグレーション**。DB を手で変更しない。
- DB 接続は `API_DATABASE_URL`（環境変数）。秘密はコミットせず、本番は Secrets Manager。

テスト DB:
- `TEST_DATABASE_URL` 未設定時は **in-memory SQLite（aiosqlite）** にフォールバック
  → docker 不要でどこでも実行可能。スキーマは `Base.metadata.create_all` で作成（Alembic は使わない）。
- **CI は Postgres**（service container）に対して `alembic upgrade head` + pytest を実行し、
  本番相当のパリティを確認する。

---

## フロントエンド: `services/web`（Vite + Vue 3 + TypeScript）

### 構造

```
services/web/
├── package.json              # scripts: dev/build/typecheck/lint/test/test:e2e/gen-types
├── vite.config.ts            # @vitejs/plugin-vue・/api プロキシ・Vitest 設定
├── tsconfig.json(.node.json) # strict, moduleResolution Bundler
├── index.html                # エントリ（#app）
├── playwright.config.ts      # E2E（testDir ./e2e）
├── .env.example              # VITE_ プレフィックスの非機密変数のみ
└── src/
    ├── main.ts               # createApp(App).use(pinia).use(router).mount('#app')
    ├── App.vue
    ├── router/index.ts       # createWebHistory のルート定義
    ├── views/                # ルートに対応するページ（HomeView.vue）
    ├── components/           # 再利用コンポーネント（HealthBadge.vue）
    ├── stores/               # Pinia ストア（counter.ts）
    └── api/                  # API アクセスの単一窓口
        ├── client.ts         #   typed な ApiClient / apiClient
        ├── schema.ts         #   ★ OpenAPI から生成（手で編集しない）
        └── index.ts
```

### 開発フロー

```bash
cd services/web
npm install
npm run dev          # Vite dev server（:5173、/api は :8000 にプロキシ）
npm test             # Vitest（ユニット）
npm run test:e2e     # Playwright（E2E）
npm run lint         # eslint
npm run typecheck    # vue-tsc --noEmit（tsc ではない）
npm run build        # vue-tsc + vite build
```

### 規約

- SFC は **Composition API + `<script setup lang="ts">`**。
- 型チェックは **`vue-tsc`**（`tsc` ではない）。`strict` モード、ESM。
- **API 呼び出しは `src/api` のクライアント経由のみ**。コンポーネントで `fetch` を直書きしない。
- フロントの環境変数は必ず **`VITE_` プレフィックス**かつ**非機密**（ビルドに同梱されブラウザに渡る）。
  秘密はサーバ側（SSM / Secrets Manager）に置く。
- 画面は `src/views/`、再利用部品は `src/components/`、共有状態は `src/stores/`（Pinia）。

---

## API 型生成（`make gen-types`）

フロントの型はバックエンドの OpenAPI から生成する。**手書きで二重管理しない。**

```bash
make gen-types
```

- 内部では api の `app.openapi()` を JSON にダンプし、`openapi-typescript` で
  `services/web/src/api/schema.ts` を生成する（サーバ起動は不要）。
- `schema.ts` は生成物。直接編集せず、API 変更時に再生成してコミットする。
- `client.ts` は生成された `paths` 型を取り込み、型安全な窓口を提供する。

> API の入出力を変えたら: スキーマ/ルーターを更新 → `make gen-types` → フロントを型に追従。

---

## まとめてチェック

```bash
make fmt     # terraform fmt / ruff format / prettier
make lint    # tflint / ruff+mypy / eslint+vue-tsc
make test    # pytest / vitest
```

コミット時は `pre-commit`（`make hooks` で有効化）が fmt/lint/security を自動実行する。
CI（`ci.yml`）も同じゲートを通すため「ローカルで green == CI で green」。

## 関連ドキュメント

- [infrastructure.md](infrastructure.md) — インフラ（Terraform 2 層）と CI/CD
- [development-environment.md](development-environment.md) — Dev Container の使い方
- [`../CLAUDE.md`](../CLAUDE.md) — アーキテクチャと規約の正
