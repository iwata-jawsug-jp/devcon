# 変更履歴

このプロジェクトのすべての重要な変更をこのファイルに記録します。

書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に準拠し、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従います。

## [Unreleased]

## [0.2.0] - 2026-07-02

### Added

- **PWA 化**（#80）: `vite-plugin-pwa` で Web App Manifest（プレースホルダーアイコン付き）と
  ビルド時生成の Service Worker を追加。`workbox` の precache 対象はビルド済み静的シェルのみで、
  `/api/*` の runtimeCaching はあえて未設定（認証導入時の他ユーザーデータ混入を避けるため）。
  Lighthouse の PWA カテゴリは upstream で削除済みのため、`e2e/pwa.spec.ts`
  （`vite preview` に対する Playwright）で manifest の妥当性と Service Worker の
  active 化を検証する。
- **ECS Application Auto Scaling**（#44）: api の ECS Fargate サービスに CPU / メモリの
  target tracking ポリシーを追加。dev はスケール実質無効（min=max=1）、prod は 1〜4 タスクで
  実際にスケールする（`env/{dev,prod}.tfvars.example`）。インフラ堅牢化（#44）の残りの項目
  （WAF・KMS CMK・秘密ローテーション・DR/バックアップ方針・環境昇格フロー）は別 PR で対応する。
- **frontend のビルド時静的生成（vite-ssg）+ SEO/OGP基盤**（#78）: `services/frontend` を
  `vite-ssg build` で全ルート prerender するように変更（cloaking なし、全ユーザーに同一の
  静的HTML）。`@unhead/vue` の `useHead()` でページ単位の title/meta/OGP/JSON-LD を宣言でき
  るようにし、`vite-ssg-sitemap` で `sitemap.xml`/`robots.txt` をビルド時自動生成する。
- **Dependabot 導入**（#113）: GitHub Actions / npm / uv / Terraform / devcontainer / Docker の
  6 ecosystem を weekly で自動更新（minor/patch はグループ化して PR 数を抑制）。Dependabot
  非対応の pre-commit rev は四半期ごとの手動 `pre-commit autoupdate` 運用を CONTRIBUTING.md に明記。
- **`make ci-frontend`**（#111）: CI の frontend ジョブ（eslint / vue-tsc / vitest / build /
  バンドル予算 / Lighthouse / e2e）をローカルで一発再現する集約ターゲット。
- **ADR-0005**（#116）: Dev Container の Docker 実行方式として docker-in-docker
  （`--privileged`）を docker-outside-of-docker と比較のうえ継続採用した決定を記録。
- **cd-app の preflight ゲート**（#145）: アプリ層のリポジトリ変数（`ECR_REPOSITORY` /
  `WEB_BUCKET` 等）が未登録の間はデプロイジョブを明示 skip し、インフラ未適用でも main の
  CD を green に保つ（変数登録で従来どおりフルデプロイ）。

### Security

- **deploy IAM ロールの最小権限化**（#45）: `infra/bootstrap/` の `ci_deploy` ロールから
  AWS 管理の `PowerUserAccess` を外し、`infra/*.tf` が実際に使うサービス（EC2ネットワーク/
  ECS/ECR/ELB/RDS/S3/CloudFront/CloudWatch Logs/Application Auto Scaling）ごとにスコープした
  inline policy に置き換えた。**`bootstrap/` は CI 管理外のため、ローカルで
  `terraform apply` するまで実環境には反映されない**。CloudTrail 等の実アクセス履歴ではなく
  静的なリソース種別分析から導出したため、適用後に `AccessDenied` が出ないか
  `cd-infra.yml`/`cd-app.yml` で確認すること。
- **trivy を三層すべてでブロッキング化**（#150）: CI の trivy-action に `exit-code: 1` を
  付与し、pre-commit フック・`make security` と挙動を統一。許容する既存 findings（6 種）は
  `.trivyignore` に理由付きで明示し、新規の HIGH/CRITICAL はどの層でも fail する。

### Fixed

- `infra/CLAUDE.md` と `.github/instructions/infra.instructions.md` が「`cd-infra.yml` は
  `production` 環境で main マージ時にゲートされる」という古い記述のままだった（実際は手動
  `workflow_dispatch` ゲート）。`docs/infrastructure.md`/`README.md` は既に修正済み（#101）
  だったが、この2ファイルは見落としていた。

### Changed

- **サービスディレクトリ改名**（#98, ADR-0004）: `services/api` → `services/backend/python`、
  `services/web` → `services/frontend` にリネーム。バックエンドは開発言語ごとにサブフォルダを
  分ける構成にし、将来 Python 以外の言語を追加できるようにした。Makefile ターゲット
  （`api-*`/`web-*` → `backend-*`/`frontend-*`）、CI/CD のパスフィルタ・Docker ビルド
  コンテキスト、`CLAUDE.md`、Copilot 用ミラーもあわせて追従。Python パッケージ内部名（`api`）
  と Terraform の AWS リソース論理名（`api`/`web`）は意図的に変更していない。
- **開発環境の再現性強化**（Epic #108）: Dev Container のツールを `ARG` でバージョン固定
  （Terraform は CI と同じ 1.13.0 に統一）（#109）、Python ランタイムを `.python-version`
  （3.14）に単一ソース化してローカル / CI / 本番イメージを揃え（#110）、`make setup` を
  postCreate で自動実行（#115）、`docs/development-environment.md` をフロントエンドの
  現状（Vite + Vue 3）に追従（#112）。
- **品質ゲート三層（pre-commit / Makefile / CI）の同期**（#111）: `make tf-lint` を CI と
  同一の `tflint --recursive --config` に統一（CI が root `.tflint.hcl` の AWS ルールセットを
  黙って無視していた問題も修正）、checkov は三層とも advisory（`--soft-fail` + 理由明記）に、
  trivy の severity を `HIGH,CRITICAL` に統一。
- **prettier フックの刷新**（#114, #127）: deprecated な mirrors-prettier（v4 alpha）を
  frontend の `node_modules/.bin/prettier` を直接使う local フックに置換し、バージョンを
  `package.json` に一元化。フック未通過だった既存 26 ファイルを一括整形し、cc-sdd 上流物
  （`.claude/skills/`・`.kiro/settings/templates/`）は整形対象外に。
  `services/frontend/.prettierignore` で生成物 `schema.ts` の整形を防止。
- **依存メジャー更新**（#147 ほか Dependabot 15 PR）: vite 8 / vitest 4（カバレッジ計測の
  AST 化に伴いテスト追加でゲート維持）/ vue-router 5 / pinia 3 / jsdom 29、GitHub Actions
  （checkout v7・setup-node v6・setup-uv v7・setup-terraform v4・paths-filter v4）、
  AWS provider 6（state が空のうちに更新）、Dev Container を Ubuntu 24.04 +
  docker-in-docker feature 4.0 に更新。

## [0.1.4] - 2026-07-01

### Added

- **カバレッジゲート** `api`（pytest-cov）・`web`（vitest）（#43）: CI にカバレッジ閾値のゲートを追加。
- **a11y CI ゲート**（#83）: `web` の e2e に axe-core によるアクセシビリティチェックを追加し、CI で有効化。
- **Lighthouse CI ＋ JS バンドルサイズ予算**（#84）: gzip 済み JS バンドルサイズの予算チェックと
  Lighthouse CI（3 回実行で単発ノイズを低減）を導入。閾値は `docs/`（#90）に記録。
- **CloudFront セキュリティヘッダー**（#79）: SPA 配信用 CloudFront にセキュリティヘッダーを追加。
  `sandbox/*` で実 AWS 適用を検証してからマージ。
- **TanStack Query 導入**（#82）: `services/web` にサーバー状態管理として `@tanstack/vue-query` を導入し、
  `HealthBadge` を移行。
- **Tailwind CSS ＋最小デザイントークン**（#81）: `@tailwindcss/vite` を導入し、ブランドカラー・フォント
  スタックのみを定義した最小トークンセットを追加。
- **ADR-0003**: #40（ドメイン機能拡充）・#41（認証・認可導入）を既存のモノレポ構成（`services/api` /
  `services/web` / `infra`）のまま吸収する決定を記録。
- **GitHub Copilot CLI 互換性ドキュメント**（#75, #76）: `.claude/skills` が Copilot CLI からも利用可能な
  ことを明記。
- **Web フロントエンドのサイトアーキテクチャ近代化 提案書**（#77）。

### Changed

- **`.devcontainer/Dockerfile`**: GitHub Copilot CLI（`@github/copilot`）へ切り替える場合の具体的な手順を
  TODO コメントとして記録（実行内容・ビルド結果への影響なし）。

## [0.1.3] - 2026-06-30

### Added

- **SDD（仕様駆動開発）ツールを導入**（Epic #66）: 上流工程（要件定義・基本設計）を成果物として
  残すため、cc-sdd を `--claude-skills` 方式で導入。`.claude/skills/kiro-*`（`/kiro-*` スキル）と
  `.kiro/`（settings / steering / 試験導入の spec `items-add-field`）を追加。提案書が前提にしていた
  `--claude`（commands）方式は cc-sdd v3.0.2 で非推奨化したため、推奨の skills 方式を採用（#60, #61）。
- **SDD 運用ドキュメント** `docs/sdd.md`（#62）: `/kiro-*` スキルの使い方・`.kiro/` 構成・
  `.kiro/specs/<feature>` → `docs/requirements|design/` への昇格手順・**cc-sdd に `CLAUDE.md` を
  所有させない保護ルール**・公開ミラー/gitignore 方針・四半期 OSS 点検を明文化。
- **ADR（Architecture Decision Record）運用を開始** `docs/adr/`（#63）: ADR-0001（運用方針）＋
  テンプレート。インフラ・アーキ上の重要判断を「なぜそう決めたか」で記録。SDD 採用の判断は
  ADR-0002 として記録（#62）。
- **基本設計の図表方針** `docs/design/`（#65）: Mermaid を既定とし、精密な AWS 構成図は Python
  `diagrams` / draw.io を補助に使う方針と、`.drawio.svg` の round-trip 注意を文書化。
- **確定要件の保管庫** `docs/requirements/`（#62）: リリース済み機能の要件を `.kiro/specs/` から
  昇格して置く場所。

### Changed

- **`CONTRIBUTING.md` に SDD 適用基準を追記**（#64）: 粒度の大きい新機能は `.kiro/specs/` で要件定義
  →基本設計→タスク分解を経てから実装、単一の小機能は `/kiro-spec-quick`、軽微な修正は Plan Mode
  （`/plan`）で十分、という線引き（過剰適用＝「Waterfall の逆襲」を回避）。
- **`CLAUDE.md` / `docs/README.md` / `docs/ai-instructions.md`**（#62, #63, #65）: 上記の新ドキュメント
  （`docs/sdd.md` / `docs/adr/` / `docs/design/`）への参照を追加。SDD 成果物（`.kiro/`）は「何を作るか」、
  実装規約（`CLAUDE.md` / Copilot instructions）は「どう書くか」と役割が異なるため、`.kiro/` を Copilot
  ミラーの対象外とすることを明記。

## [0.1.2] - 2026-06-30

### Added

- **SDD ツール導入提案書** `docs/proposal/sdd-tooling-proposal.md`（#67）: 実装フェーズの
  ガードレールは整っている一方で空白だった**上流工程**（業務整理 → 要件定義 → 基本設計）に、
  cc-sdd を中心とした **SDD（Spec-Driven Development）** ツールを段階的導入する提案。推奨案
  （cc-sdd、合わなければ GitHub Spec Kit へ切替）・推奨ディレクトリ構成（`.kiro/` ↔ `docs/`）・
  運用フロー・ロードマップ・留意点を整理。実現施策は Epic #66（子タスク #60–#65）として起票済み。

## [0.1.1] - 2026-06-29

### Changed

- **README を再編**（#57）: 「概要 / クイックスタート（ローカル）/ 本格セットアップ（自分の
  AWS で実開発）/ リファレンス」の 4 ブロック構成へ。ローカル開発（AWS 不要）と本格セットアップ
  （AWS 必要）を明確に分離し、公開リポジトリを fork して実開発を始めるまでの導線を追加。新サブ
  セクション「自分の AWS にデプロイする」で、`infra/bootstrap/` の `github_org` / `github_repo`
  を自分の fork に差し替える点（OIDC trust がリポジトリ限定のため）と リポジトリ変数 3 つの登録
  を要約（実体は `docs/infrastructure.md` を参照）。fork 手順は `<your-org>/<your-repo>` の
  プレースホルダで記述し、公開ミラー変換の整合を保つ。

## [0.1.0] - 2026-06-29

### Added

- **GitHub Copilot ルール化**（#54）: 既存の `CLAUDE.md` 群のガードレールを Copilot
  （IDE Chat / coding agent / code review）にも効かせるため、Copilot ネイティブの指示
  ファイルを追加。リポジトリ全体ルールの `.github/copilot-instructions.md` と、ネスト
  `CLAUDE.md` を `applyTo` グロブで 1:1 ミラーする `.github/instructions/` 配下の
  backend / frontend / infra 各 `*.instructions.md`。詳細は `docs/` 参照型の薄い抽出に
  留め、`CLAUDE.md` と同じ英語で記述してドリフト検出を容易にした。
- **AI 開発ルールの同期手順** `docs/ai-instructions.md`: ルールの「正」を `docs/` に一本化し、
  `docs/` ＋ `CLAUDE.md` ＋ Copilot 用ファイルを 1 PR でまとめて変更する運用を明文化
  （ファイル対応表・ドリフト点検・既知の制約）。`docs/README.md` とルート `CLAUDE.md` から参照。
- README に CI / Release バッジを追加（#53）。

## [0.0.6] - 2026-06-29

### Changed

- **`CLAUDE.md` を最適化**（毎セッション常時ロードの軽量化, #47）: ルートを高シグナルな
  ~50 行に圧縮し、落とし穴を `## Critical rules` として前方集約。領域固有の規約は
  path-scoped な nested `CLAUDE.md`（`services/api/` / `services/web/` / `infra/`）へ降ろし、
  そのサブツリーを触ったときだけ on-demand ロードする構成に。詳細は `@` なしのプレーン参照
  （raw SQL 禁止 / Alembic 必須 / `vue-tsc` / `make gen-types`）を各 1 箇所へ集約。
- Working from issues フローを `docs/issues.md` として新規切り出し（ルートから参照）。
- **`cd-infra.yml`**: `backend.hcl` / `*.tfvars` を git-ignored の `.example` から CI 実行時に
  生成する方式へ（state バケット名はリポジトリ変数 `AWS_TF_STATE_BUCKET` で注入。秘密値は
  git・ログに出さず、`*.example` のみコミットの方針を維持）。bootstrap 適用後に PR の
  `terraform plan` が CI で通るようになった（#49, #50）。
- **apply の承認ゲート変更**: private リポジトリ＋現プランでは GitHub Environment の
  required reviewers が使えないため、`apply` を main push 自動実行から手動
  `workflow_dispatch` に変更（`push: main` トリガー削除）。マージで prod が自動 provision
  されず、手動実行そのものをゲートとする。恒久化手順（Enterprise / Team / Pro 移行・
  public 化）は `docs/infrastructure.md` に追記（#50, #51）。

### Fixed

- **CI（cd-infra）**: OIDC のロール ARN / state バケット名が未登録のため `plan` / `apply` が
  認証・`init` 段階で失敗していた問題を、`infra/bootstrap/` 適用＋リポジトリ変数
  （`AWS_PLAN_ROLE_ARN` / `AWS_DEPLOY_ROLE_ARN` / `AWS_TF_STATE_BUCKET`）の登録で解消（#49）。

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

[Unreleased]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.1.4...v0.2.0
[0.1.4]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.0.6...v0.1.0
[0.0.6]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/iwata-jawsug-jp/devcon/releases/tag/v0.0.1
