# アプリケーション開発ガイド

`services/backend/python`（バックエンド）と `services/frontend`（フロントエンド）の
開発手順・構造・規約。全体のアーキテクチャは [`../CLAUDE.md`](../CLAUDE.md) を参照。

## アーキテクチャ概要

```
ブラウザ ──/api/*──▶ frontend (Vite:5173)  ──proxy──▶  backend (uvicorn:8000)
            静的 SPA(Vue3)                              REST API(FastAPI)
```

- `frontend` は静的 SPA、`backend` はステートレスな JSON API。別プロセス。
- ブラウザは相対パス `/api/*` で API を呼ぶ。**開発時**は Vite が `/api/*` を
  uvicorn(:8000) にプロキシ（CORS 不要）。**本番**は CloudFront が `/api/*` を api
  オリジンへルーティング。
- ブラウザが AWS を直接叩くことはない。データは必ず `backend` を経由する。
- API 契約は FastAPI の OpenAPI（`/openapi.json`）が単一の正。フロントの型はそこから
  **生成**する（`make gen-types`）。型を二重に手書きしない。

## ローカル起動

```bash
make dev    # backend(:8000) と frontend(:5173) を同時起動
```

- アプリ: http://localhost:5173
- API ドキュメント（Swagger UI）: http://localhost:8000/docs
- 個別起動: `make backend-dev` / `make frontend-dev`

---

## バックエンド: `services/backend/python`（FastAPI）

`backend/` は開発言語ごとにサブフォルダを分ける構成。将来 Python 以外の言語でバックエンド
サービスを追加する場合は `services/backend/<言語>/` として並置する
（[ADR-0004](adr/0004-rename-services-by-role-and-nest-backend-by-language.md) 参照）。
Python パッケージ名・import 文（`api.xxx`）はディレクトリの深さと独立しており、
このリネームでは変更していない。

### 構造

```
services/backend/python/
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
cd services/backend/python
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
- ruff（line length 100 / `py314`）、mypy strict、型ヒント必須。

### エンドポイントを追加するには

1. `src/api/schemas/` に Pydantic モデルを追加。
2. `src/api/routers/` に `APIRouter` を作り、`async` ハンドラを `response_model` 付きで定義。
3. `src/api/main.py` で `app.include_router(...)`。
4. `tests/` に `TestClient` のテストを追加。
5. フロントで使うなら `make gen-types` で型を再生成（後述）。

### データベース（SQLAlchemy async + Alembic）

`backend` は PostgreSQL に永続化する。ローカルは docker-compose の Postgres、本番は RDS。

```
services/backend/python/
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
cd services/backend/python && uv run pytest # テスト（後述のとおり既定は SQLite）
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

## フロントエンド: `services/frontend`（Vite + Vue 3 + TypeScript）

### 構造

```
services/frontend/
├── package.json              # scripts: dev/build(=vite-ssg build)/typecheck/lint/test/test:e2e/gen-types
├── vite.config.ts            # @vitejs/plugin-vue・/api プロキシ・ssgOptions・Vitest 設定
├── tsconfig.json(.node.json) # strict, moduleResolution Bundler
├── index.html                # エントリ（#app）
├── playwright.config.ts      # E2E（testDir ./e2e）
├── .env.example              # VITE_ プレフィックスの非機密変数のみ（VITE_SITE_URL 等）
└── src/
    ├── main.ts               # ViteSSG(App, { routes }, setup) — createApp を直接呼ばない
    ├── App.vue                #   サイト共通の titleTemplate（useHead）
    ├── router/index.ts       # ルート定義（RouteRecordRaw[]。vite-ssg がこれで router を構築）
    ├── views/                # ルートに対応するページ（HomeView.vue、各ページで useHead）
    ├── components/           # 再利用コンポーネント（HealthBadge.vue）
    ├── stores/               # Pinia ストア（counter.ts、クライアントのみの状態）
    └── api/                  # API アクセスの単一窓口
        ├── client.ts         #   typed な ApiClient / apiClient
        ├── schema.ts         #   ★ OpenAPI から生成（手で編集しない）
        ├── queries.ts        #   TanStack Query の composable（useHealthQuery 等）
        └── index.ts
```

### 開発フロー

```bash
cd services/frontend
npm install
npm run dev          # Vite dev server（:5173、/api は :8000 にプロキシ）
npm test             # Vitest（ユニット）
npm run test:e2e     # Playwright（E2E）
npm run lint         # eslint
npm run typecheck    # vue-tsc --noEmit（tsc ではない）
npm run build        # vue-tsc + vite-ssg build（下記「静的生成」参照）
```

### 規約

- SFC は **Composition API + `<script setup lang="ts">`**。
- 型チェックは **`vue-tsc`**（`tsc` ではない）。`strict` モード、ESM。
- **API 呼び出しは `src/api` 経由のみ**。コンポーネントで `fetch` を直書きしない（サーバー状態の
  取得方法は次項）。
- フロントの環境変数は必ず **`VITE_` プレフィックス**かつ**非機密**（ビルドに同梱されブラウザに渡る）。
  秘密はサーバ側（SSM / Secrets Manager）に置く。
- 画面は `src/views/`、再利用部品は `src/components/`。

### サーバー状態の取得（TanStack Query、#82）

**サーバーから取得するデータは TanStack Query（`@tanstack/vue-query`）、クライアントのみの状態は
Pinia** という役割分担にする。

- コンポーネントは `apiClient` を直接呼ばず、`src/api/queries.ts` の `useXxxQuery()` composable
  経由でデータ取得する（例: `HealthBadge.vue` の `useHealthQuery()`）。新しいエンドポイントを
  使うコンポーネントを書くときは、まず `queries.ts` に対応する composable を追加する。
- `queries.ts` 内部で `apiClient`（生成された OpenAPI 型付きクライアント）を呼ぶ。コンポーネントから
  `apiClient` を直接 import しない。
- キャッシュ・再試行・ローディング/エラー状態は TanStack Query に任せ、手組みしない。
- Pinia（`src/stores/`）は**サーバーに存在しないクライアントのみの状態**（UI の開閉状態等）に
  用途を限定する。サーバー由来のデータを Pinia ストアへコピーして同期しない。
- `main.ts` で `app.use(VueQueryPlugin)` を必ず登録する。

### スタイリング / デザインシステム（#81）

**Tailwind CSS v4 + 最小デザイントークン**を採用する（`vite.config.ts` の `@tailwindcss/vite`、
`src/main.css` の `@theme` ブロック）。フルのコンポーネントライブラリ（PrimeVue / Naive UI /
shadcn-vue 系）は**現時点では導入しない**。

- 検討した理由: アプリの UI 面がまだ小さく（`HealthBadge` 等ごく少数）、フルライブラリはバンドル
  サイズ・カスタマイズコストに対してリターンが薄い。Tailwind のユーティリティ + 必要最小限の
  トークン（ブランドカラー・フォントスタックのみ）の方が現状の規模に合う。
- トークンは Tailwind の既定スケール（spacing/type scale 等）をそのまま使い、`@theme` には
  プロジェクト固有の値（`--color-brand-*`, `--font-sans`）のみを追加する。使う予定のないトークンを
  先回りして作らない。
- **Storybook 等のコンポーネントカタログは現時点では導入しない**。コンポーネント数が増え、
  カタログ化のメリットがコストを上回る規模になったら再検討する。
- 再検討タイミング: UI 面が増え、①フルライブラリの機能（フォーム部品・日付選択・データテーブル等）
  が繰り返し必要になる、②デザイントークンが Tailwind の既定を大きく超えて増える、のいずれかが
  発生したら本方針を見直す。

### 公開ページの静的生成（vite-ssg）と SEO/OGP（#78）

**すべてのルートを build-time prerender する**（[vite-ssg](https://github.com/antfu-collective/vite-ssg)、
`package.json` の `build` スクリプトが `vite build` ではなく `vite-ssg build`）。全ユーザーに同一の
静的 HTML を返す方式で、ボット判定でコンテンツを出し分ける dynamic rendering / cloaking はしない。

- `src/main.ts` は `createApp(App).mount(...)` ではなく
  `export const createApp = ViteSSG(App, { routes }, setup)` を使う。`setup` で Pinia /
  TanStack Query 等のプラグインを登録する。
- `src/router/index.ts` は router インスタンスではなく **`routes`（`RouteRecordRaw[]`）を export
  するだけ**にする。router 自体は `vite-ssg` が構築する。
- ページタイトル・meta・OGP・構造化データ（JSON-LD）は各ページの `<script setup>` で
  `@unhead/vue` の `useHead()` を呼んで宣言する（`HomeView.vue`参照）。サイト共通のタイトル
  テンプレートは `App.vue` の `useHead({ titleTemplate: ... })` に置く。
- **今は全ルートが「公開ページ」なので `vite.config.ts` の `ssgOptions` は素通し**。将来
  認証必須のアプリルート（#41 以降）が増えたら `ssgOptions.includedRoutes` でそれらを除外し、
  公開 LP だけ prerender・それ以外は従来どおり CSR SPA、という構成に切り替える。
- `sitemap.xml` / `robots.txt` は `vite-ssg-sitemap` が `ssgOptions.onFinished` フックで
  ビルド時に自動生成する（`vite.config.ts`）。ホスト名は `VITE_SITE_URL` 環境変数
  （未設定時は `http://localhost:5173` にフォールバック）。
- CI（`ci.yml`）の `Build` ステップがそのまま prerender ビルドの成功を検証する
  （`vite-ssg build` が失敗すれば CI が red になる）。

### PWA（Web App Manifest + Service Worker、#80）

`vite-plugin-pwa`（`vite.config.ts`）で Web App Manifest とビルド時生成の Service Worker を
追加している。

- `registerType: 'autoUpdate'` + `workbox.clientsClaim`/`skipWaiting`: 新しい SW は即座に
  有効化され、ユーザーは常に最新デプロイを見る（タブを全部閉じるまで待たない）。
- **`workbox.globPatterns` で precache するのはビルド済みの静的シェル（JS/CSS/HTML/アイコン）
  のみ**。`/api/*` への runtimeCaching は意図的に未設定 — 認証必須のルート（#41 以降）ができた
  ときに、Service Worker が別ユーザーのレスポンスをキャッシュして返す事故を避けるため。
  認証導入時はこのファイルの `workbox` 設定を見直す。
- アイコン（`public/pwa-*.png`, `public/apple-touch-icon.png`, `public/icon.svg`）は
  **プレースホルダー**（ブランドカラーの単色角丸スクエア + "OD" の文字）。実際のロゴが
  決まったら差し替える。
- `theme-color` メタタグと `apple-touch-icon` の `<link>` は `vite-plugin-pwa` が自動注入しない
  ため、`App.vue` の `useHead()` に手動で追加している。
- **検証**: Lighthouse の PWA カテゴリ（`installable-manifest`/`service-worker` 監査）は
  upstream で削除済み（`lighthouse@12` 時点で存在しない）ため、代わりに
  `e2e/pwa.spec.ts`（Playwright）で「manifest が有効か」「Service Worker が active か」を
  自動検証する。この spec だけ `vite preview`（本番ビルド）に対して実行する
  （`playwright.config.ts` の `chromium-pwa` プロジェクト）。**Service Worker は
  `npm run dev` では登録されない**ため、通常の `chromium` プロジェクトの対象外にしている。

### 品質ゲート（カバレッジ / a11y / パフォーマンス予算）

CI（`ci.yml`）が強制するしきい値と計測方法。数値は現状のベースラインに合わせた「まず割らせない
床」で、実装が増えるにつれ引き上げる前提（閾値自体を下げる変更は理由を issue に残す）。

| ゲート                    | しきい値                                                               | 計測方法                                                                                                                                                                                                                                         |
| ------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| backend カバレッジ        | `--cov-fail-under=90`（現状 ~97%）                                     | `pyproject.toml` の `addopts`（`pytest-cov`）。`uv run pytest` / `make backend-test` で自動適用                                                                                                                                                  |
| frontend カバレッジ       | lines/statements 35%・functions 45%・branches 55%（現状 ~39%/50%/62%） | `vite.config.ts` の `test.coverage.thresholds`（`@vitest/coverage-v8`）。`npm test` で自動適用                                                                                                                                                   |
| a11y                      | WCAG 2.0/2.1/2.2 の A+AA タグで違反ゼロ                                | `e2e/home.spec.ts` の `@axe-core/playwright` スキャン（Playwright e2e の一部として CI で実行）                                                                                                                                                   |
| Core Web Vitals（lab）    | LCP ≤2.5s・CLS ≤0.1・Total Blocking Time ≤300ms（INP のラボ代替指標）  | `lighthouserc.json`（Lighthouse CI、`dist/` を `staticDistDir` で直接計測）                                                                                                                                                                      |
| Lighthouse カテゴリスコア | performance / accessibility とも ≥0.9                                  | 同上                                                                                                                                                                                                                                             |
| JS バンドル予算（gzip）   | script 400KB・stylesheet 100KB・total 600KB                            | `budget.json` を `scripts/check-bundle-budget.mjs` が読み、`dist/assets/` の実際の gzip サイズと突き合わせる（`npm run check:bundle-budget`）。Lighthouse 本体の `performance-budget`/`timing-budget` オーディットは上流で削除済みのため使わない |

> 実際の INP（Interaction to Next Paint）はフィールドデータが必要で lab 計測では代替不可。
> フロントエンドの RUM/エラートラッキングは可観測性エピック（issue #42）の範囲。

---

## API 型生成（`make gen-types`）

フロントの型はバックエンドの OpenAPI から生成する。**手書きで二重管理しない。**

```bash
make gen-types
```

- 内部では backend の `app.openapi()` を JSON にダンプし、`openapi-typescript` で
  `services/frontend/src/api/schema.ts` を生成する（サーバ起動は不要）。
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
