# Technology Stack

## Architecture

静的 SPA（web）と ステートレス JSON API（api）を**別プロセス**で動かす 3 層構成。ブラウザは
`/api/*` のみ呼ぶ（dev は Vite が uvicorn にプロキシ、prod は CloudFront が api オリジンへ
ルーティング）。ブラウザは AWS を直接触らない。api は SQLAlchemy async で PostgreSQL
（prod は RDS、ローカルは docker-compose）に永続化。API 契約は FastAPI の OpenAPI スキーマが正で、
フロントの型はそこから生成する（二重定義しない）。

## Core Technologies

- **Language**: Python（api）/ TypeScript（web）
- **Framework**: FastAPI + uvicorn（api）/ Vite + Vue 3（web, Composition API・vue-router・Pinia）
- **Runtime**: Python 3.14 / Node 24（Dev Container プリインストール）
- **IaC**: Terraform（AWS, `ap-northeast-1`）、2 層構成（`infra/bootstrap/` ＋ アプリ層）

## Key Libraries

- backend: SQLAlchemy 2.0 async（asyncpg）＋リポジトリパターン、Alembic（マイグレーション）、
  Pydantic / pydantic-settings
- frontend: vue-router・Pinia・vue-tsc（型チェック）・Vitest・Playwright
- 型生成: OpenAPI（`/openapi.json`）→ `services/frontend/src/api/schema.ts`（`make gen-types`）

## Development Standards

### Type Safety

- web は `vue-tsc` で型チェック。API 由来の型は**手書きせず** `make gen-types` で生成する。
- raw SQL は禁止（SQLAlchemy 経由）。スキーマ変更は必ず Alembic マイグレーションで。

### Code Quality

- `pre-commit`（fmt / lint / security）。`--no-verify` でフックを回避しない。
- 「green locally == green in CI」。ゆるいローカル変種ではなく CI と同じコマンドでミラーする。

### Testing

- api: pytest。`TEST_DATABASE_URL` 未設定時は in-memory SQLite にフォールバック、CI は Postgres
  service container で `alembic upgrade head` + pytest。
- web: Vitest（unit）/ Playwright（E2E）。

## Development Environment

### Required Tools

Dev Container（Terraform / AWS CLI / Python / Node / Claude Code）。`make hooks` で pre-commit を一度有効化。

### Common Commands

```bash
# Dev:   make dev          # Postgres → api(:8000) + web(:5173)
# Types: make gen-types    # OpenAPI からフロント型を再生成
# Test:  make test
# Lint:  make lint / make fmt / make security
# DB:    make db-up / make migrate / make makemigration
```

## Key Technical Decisions

- **キーレス CD**: 長期 AWS キーを持たず GitHub OIDC でジョブ単位の IAM ロール引受
  （PR=read-only plan、main=deploy）。`terraform apply`/`destroy` やイメージ push を手元で実行しない。
- **秘密の扱い**: `.env`/`*.tfvars`/鍵は git-ignore、`*.example` のみコミット。フロント env は
  `VITE_` プレフィックスの非機密のみ（ブラウザに出る）。バックエンド秘密は SSM / Secrets Manager。
- **state**: S3 ネイティブロック（`use_lockfile`）。詳細は `docs/`（正）・`docs/adr/` を参照。

### 認可 scope 追加時のチェックリスト（3点セット）

新しい OAuth scope（例: `api/orders.read`）を追加する機能は、design.md / tasks.md のタスク分解に
必ず次の3点を含める。1つでも欠けると、実 Cognito ログインでのみ再現する 403（トークンに scope が
含まれない）という形で顕在化し、CI では検出できない（#438 背景: 第2消費者実証での実例）。

1. `infra/auth.tf` — resource server の `scope` ブロックと `allowed_oauth_scopes` に追加
2. バックエンド — 該当エンドポイントに `require_scope("api/xxx.yyy")` を追加
3. **フロントエンド** — `services/frontend/src/auth/oidcConfig.ts` の scope 定数（ログイン時に
   要求する scope 一覧）に追加。ここが最も漏れやすい。

---

_Document standards and patterns, not every dependency_
