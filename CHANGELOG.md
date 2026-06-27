# 変更履歴

このプロジェクトのすべての重要な変更をこのファイルに記録します。

書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に準拠し、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従います。

## [Unreleased]

## [0.0.5] - 2026-06-27

### Added

- **アプリ実行基盤**（`infra/`）: **ECS Fargate + ALB**（CloudFront 経由で `/api/*`）、
  **VPC エンドポイント**（ECR/logs/secretsmanager + S3 gateway、NAT なしで private タスクが
  pull/secret 取得）、**CloudFront + OAC**（default→S3 SPA, `/api/*`→ALB, SPA エラー応答）、
  ECS 実行/タスク IAM ロール、api タスク定義（DB を env + Secrets Manager 注入）。3 層アプリを
  実 AWS にデプロイ可能化。
- **sandbox 開発環境**: `sandbox/*` 隔離ブランチで CI/CD を実 AWS 検証。専用ワークフロー
  `ci-sandbox.yml` / `cd-infra-sandbox.yml` / `cd-app-sandbox.yml`（`push:[sandbox/**]`）、
  `sandbox-guard.yml` + GitHub ルールセットで **`sandbox/*` → 非 sandbox のマージを禁止**、
- bootstrap の deploy ロールに **プロジェクト限定の IAM 管理権限**（ECS ロール作成 / PassRole /
  ServiceLinkedRole）を付与。deploy 信頼に `refs/heads/sandbox/*` を追加。
- 運用ドキュメント: `CLAUDE.md` に「Working from issues」と sandbox ポリシー、
  `docs/infrastructure.md` に bootstrap 適用前の CI 挙動・ロール ARN 登録手順を追記。

### Changed

- **`cd-app.yml`**: デプロイを「ビルドした image で **新タスク定義リビジョンを登録** →
  そのリビジョンで migration（`uv run --no-sync alembic upgrade head`）→ サービスを新リビジョンへ
  roll」に変更（ECR は IMMUTABLE タグのため `force-new-deployment` だけでは新イメージが反映され
  なかった問題を解消）。変数 `MIGRATION_TASK_DEFINITION` → `ECS_TASK_FAMILY`。
- **api 設定**（`config.py`）: `API_DB_*` コンポーネントから `database_url` を組み立て
  （ECS の env + Secrets Manager 注入に対応）。
- Claude Code `.claude/settings.json`: **read-only な aws を allow**（`terraform apply`/`destroy`・
  `aws:*` 変更系は `ask` 維持）。
- CI/CD のワークフローを Terraform `1.13.0` に統一（`required_version >= 1.11` 要件）。

### Fixed

- **CI**: `pull_request` 起動の CI が `changes` ジョブの権限不足（`pull-requests: read` 欠如）で
  常に失敗していた問題を修正。
- **CI（infra）**: `trivy-action` の無効タグを `@v0.36.0` に、Terraform バージョン不整合を解消、
  tflint の未使用宣言（変数 / bootstrap の data source）を整理。
- **`services/api/Dockerfile` / `.dockerignore`**: `README.md` 除外解除、Alembic 設定/マイグレーション
  の同梱、`uv run --no-sync`（private subnet に egress が無くてもビルド/マイグレーションが通る）。

## [0.0.4] - 2026-06-27

### Added

- **データベース層**を追加。`api` は PostgreSQL に永続化する。
  - アプリ: SQLAlchemy 2.0 async（asyncpg）＋リポジトリパターン、Alembic マイグレーション。
    in-memory store を `ItemRepository` + `Depends(get_session)` に置換。`API_DATABASE_URL` 設定。
  - ローカル: `docker-compose.yml`（`postgres:16`）と `make db-up`/`migrate`/`makemigration`。
  - テスト: `TEST_DATABASE_URL` 未設定時は in-memory SQLite にフォールバック、CI は Postgres
    service container で `alembic upgrade head` + pytest を実行。
- **インフラ**: 最小 VPC（2 AZ・public/private subnet・IGW、app/db セキュリティグループ）と
  **RDS for PostgreSQL**（private subnet・保管時暗号化・非公開・`manage_master_user_password`
  による Secrets Manager マネージド認証・IAM 認証・Performance Insights）。
- **CD**: `cd-app.yml` に **マイグレーション専用ジョブ**を追加（`aws ecs run-task` で
  `alembic upgrade head` を VPC 内の一回限り Fargate タスクとして実行し、成功後にサービス更新）。
- ドキュメント（`CLAUDE.md` / `docs/app-development.md` / `docs/infrastructure.md`）に DB 節を追記。

## [0.0.3] - 2026-06-27

### Changed

- Terraform の state ロックを **DynamoDB から S3 ネイティブロック**（`use_lockfile = true`）へ移行。
  DynamoDB ロックテーブル・関連変数/出力/IAM 権限を削除し、`required_version` を `>= 1.11` に。
  `env/*.backend.hcl.example` を `use_lockfile = true` に更新。

### Security

- bootstrap の state バケットに、**非 HTTPS（平文 HTTP）アクセスを拒否**するバケットポリシー
  （`aws:SecureTransport=false` を Deny）を追加。

### Added

- インフラ論理構成図 `docs/images/infra-architecture.drawio.svg`（draw.io で編集可能な
  `*.drawio.svg`）を追加し、`docs/infrastructure.md` から参照。

## [0.0.2] - 2026-06-27

### Changed

- アプリ構成を刷新: バックエンドを **FastAPI**（uvicorn、`/api` 配下のルーター・
  Pydantic スキーマ・`pydantic-settings`）に、フロントエンドを **Vite + Vue 3 + TS**
  （Composition API・vue-router・Pinia・vue-tsc・Vitest・Playwright）に変更。
- API 契約を OpenAPI に一本化し、フロントの型を `make gen-types` で生成
  （`services/web/src/api/schema.ts`）。
- `infra/` を 2 層化: `infra/bootstrap/`（初回・ローカル state: state バケット /
  DynamoDB ロック / GitHub OIDC / CI IAM ロール）とアプリ層（リモート state、部分 backend）。

### Added

- GitHub Actions の CI/CD: `ci.yml`（パスフィルタ per-service）/ `cd-infra.yml`
  （PR で plan、main で apply・`production` 環境ゲート）/ `cd-app.yml`
  （ECR/ECS・S3/CloudFront）。AWS 認証は GitHub OIDC のロール引受で長期キーなし。
- `services/api/Dockerfile`（CD 用イメージ）と env 別 `tfvars` / `backend.hcl` の `*.example`。
- 開発ガイド `docs/app-development.md` と `docs/infrastructure.md`。
- Makefile に `dev` / `gen-types` / `api-dev` / `web-*` ターゲットを追加。

## [0.0.1] - 2026-06-27

### Added

- モノレポの初期構成: `infra/`(Terraform)、`services/api/`(Python・uv)、
  `services/web/`(Node/TypeScript)、`Makefile`、`pre-commit` 設定。
- Dev Container 定義（Terraform / AWS CLI / Python 3.14 / Node 24 / セキュリティツール）。
- AWS SSO セットアップスクリプト `tools/script/aws-sso-setup.sh` を追加し、
  `tools/script` を `PATH` に追加。`sso_account_id` と SSO start URL は環境固有のため
  必須オプション（既定値を埋め込まない）。
- ユーザー設定（`~/.aws` / `~/.config/gh` / `~/.claude` / `~/.history`）を名前付き
  Docker ボリュームで永続化。`init-persist.sh` で rebuild ごとに所有者を是正。
- Claude Code の設定・認証を `CLAUDE_CONFIG_DIR` で `~/.claude` に集約し永続化。
- プロジェクトメタファイル: `LICENSE`(MIT) / `CONTRIBUTING.md` /
  `CODE_OF_CONDUCT.md` / `CHANGELOG.md`。
- 開発環境ガイド `docs/development-environment.md` と `docs/README.md`。
- 公開用リポジトリ（`iwata-jawsug-jp/devcon`）への変換パブリッシュ・ワークフロー
  （Release 公開時に `devcon` → `devcon` へ変換してスナップショット公開）。
- README に Git / Claude Code / AWS SSO の初期設定手順と MIT ライセンス表示を追記。

[Unreleased]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.0.5...HEAD
[0.0.5]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/iwata-jawsug-jp/devcon/releases/tag/v0.0.1
