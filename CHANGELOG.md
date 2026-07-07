# 変更履歴

このプロジェクトのすべての重要な変更をこのファイルに記録します。

書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に準拠し、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従います。

## [Unreleased]

## [0.2.8] - 2026-07-07

### Fixed

- **`ci_deploy`ロールの権限不足・無効ステートメントを実機検証で洗い出して解消**（#258 /
  #334 / #338）。sandbox 実機での apply→destroy フルライフサイクル検証により、静的分析
  （PR #107）では検出できなかった以下を修正:
  - RDS が呼び出し元の代わりに行う KMS 操作の権限が皆無で、暗号化 RDS インスタンス作成が
    `KMSKeyNotAccessibleFault` で失敗していた。デフォルト AWS 管理キー（`alias/aws/rds`・
    `alias/aws/secretsmanager`）への `kms:DescribeKey` と、rds キーへの `kms:CreateGrant` を
    追加（#334）
  - `manage_master_user_password = true` でのマスターシークレット作成に必要な
    `secretsmanager:CreateSecret`/`TagResource`（`rds!*` スコープ）を追加（#334）
  - `EcsTaskDefinitions` ステートメントが**実在しない条件キー** `ecs:task-definition-family`
    により無言で無効化されており、`ecs:RegisterTaskDefinition` が AccessDenied になっていた。
    task-definition ARN スコープへ修正し、`default_tags` が作成時に評価する
    `ecs:TagResource` も追加（#338）
  - `ecs:RunTask` が task-definition リソースタイプに対して評価されるのに cluster 等の ARN
    にしか許可されておらず、一度もマッチし得ない無効グラントだった問題を task-definition
    ARN スコープのステートメントへ移動（PR #339 レビューで発見）
  - destroy 時に provider が `DeleteRole` の前に必ず呼ぶ `iam:ListInstanceProfilesForRole`
    が不足しており、IAM ロール削除が失敗していた（PR #341）

### Security

- **`ci_deploy` の KMS/ECS 権限を CloudTrail 証跡ベースの最小構成にトリム**: どの実機 run
  でも行使されなかった `kms:ListGrants`・`ecs:ListTaskDefinitions`・`ecs:UntagResource`・
  `ecs:ListTagsForResource` を削除し、`kms:CreateGrant` に
  `kms:GrantIsForAWSResource = true` 条件を付与（AWS サービス経由の grant 作成に限定）。

> この一連の検証により `ci_deploy` ロールの apply→destroy フルライフサイクルが最小権限で
> 実機検証済みとなり、#45 / #258 は完了。フォローアップとして、実在しない条件キーを CI で
> 静的検出するゲートの追加を #340 で追跡する。

## [0.2.7] - 2026-07-06

### Added

- **複数フレームワーク比較デモの構成案**: 学習・比較目的で複数フロントエンドフレームワーク
  実装を並べるための構成案を `docs/frontend-frameworks-demo.md` に追加。本番の
  `services/frontend/`（Vue 3）は変更せず、`sandbox/ec-site-demo` と同じブランチ分離方式
  （sandbox ブランチ内 `demos/frontend-frameworks/<framework>/`）を踏襲する方針を記録。

### Changed

- **モノレポ評価レポート（#153）の低優先度指摘を解消**（#306）:
  - backend バージョンの三重不一致を解消（`__init__.py` を `pyproject.toml` に合わせた）
  - `GET /api/items` に `limit`（既定 50・上限 100）/`offset` によるページネーションを追加
  - ruff に `S`（bandit 相当）ルールを追加（Cognito の `token_use` クレーム値を誤検知した
    3 件は `# noqa` + 理由コメントで対応）
  - frontend のカバレッジ閾値を実測値に合わせて引き上げ（`35/35/45/55` → `90/90/90/80`）
  - `index.html` の `lang="en"` と日本語コンテンツの不一致を `lang="ja"` に修正（vite-ssg の
    SSR レンダリングが `htmlAttrs` 未指定だと上書きする問題を含む）
  - プレースホルダ `<h1>web</h1>` を `devcon` に変更
  - `ci.yml` に Playwright ブラウザバイナリのキャッシュ、`cd-app.yml`/`cd-app-sandbox.yml`
    を buildx + GitHub Actions キャッシュに変更
  - `cd-infra.yml` の plan コメントを隠しマーカーで検索し、既存コメントを更新するよう変更
    （sticky 化）
  - VPC エンドポイント（ECR api/dkr・Logs・Secrets Manager・xray）を dev/sandbox のみ
    単一 AZ 化し、固定費を削減（`var.vpce_single_az`）
  - sandbox/prod で deploy role を分離しない現状維持を決定し、実際の環境隔離が
    sandbox-guard と `TF_ENV` 固定に依存している実態を `docs/infrastructure.md` に明記
  - `.env.example` に不足していた component-based DB 設定・分散トレーシング関連の変数を追記
- **`metrics-dora.yml`/`perf.yml` の `schedule`（cron）トリガーを削除し `workflow_dispatch` 限定に
  変更**: この monorepo は学習・デモ目的で実トラフィックがなく、定期実行しても意味のあるデータが
  貯まらないため。本番運用のアプリで再有効化する手順を `docs/infrastructure.md` に「アプリ開発時の
  初期設定事項」として追記。


### Security

- **`cd-infra.yml` の prod apply が main 以外のブランチからの `workflow_dispatch` でも
  実行できた問題を修正**（#301）: deploy ロールの OIDC 信頼条件が `environment:production`
  の宣言だけで満たされてしまうため、job の `if` に `github.ref == 'refs/heads/main'` を
  追加し、main 以外からの手動実行は skip されるようにした。
- **items API の入力長が無制限で、認証済みユーザーによる DB ストレージ圧迫を防げない
  問題を修正**（#305）: `name`（上限 200 文字）/`description`（上限 2000 文字）を追加。
- **`ci_deploy` ロールの実機検証（#258, #45 follow-up）で判明した不足権限を順次追加**:
  sandbox 環境での `terraform apply` 実機検証により、以下の権限不足が判明・修正した
  （**検証は継続中で、本項目は今後の PR で更新される見込み**）。
  - Cognito（#41）・SNS/CloudWatch アラーム・ダッシュボード（#42）がポリシーに
    一切含まれていなかった
  - VPC エンドポイント作成・RDS サブネットグループ操作関連の `ec2:DescribePrefixLists`/
    `DescribeNetworkInterfaces`、`rds:AddTagsToResource` 等で `subgrp:` リソースへの
    スコープが漏れていた
  - インラインポリシーがロール全体で共有する 10,240 バイト上限を超過したため、8 本すべてを
    カスタマー管理ポリシー（`aws_iam_policy` + `aws_iam_role_policy_attachment`）に変更
  - S3 バケットの付随設定読み取り系（Acl/CORS/Website/Logging 等）が不足していた
  - Cognito MFA 設定の読み取り、RDS `CreateDBInstance` の `subgrp:` リソースへの
    スコープ漏れを追加

### Fixed

- **ECS `api` サービスがデプロイ失敗時に自動ロールバックしない問題を修正**（#302）:
  `deployment_circuit_breaker`（`enable = true, rollback = true`）を追加。
- **ECR のタグ付きイメージ・S3 の非現行バージョンが無期限に蓄積する問題を修正**（#303）:
  lifecycle policy を追加（ECR は直近 30 世代、S3 state バケットは 90 日、web バケットは
  30 日で expire）。state バケット側の変更は `infra/bootstrap/` 層のため、実 AWS への反映
  には手動 `terraform apply` が必要。
- **未捕捉の例外が FastAPI デフォルトの素の 500 を返し、`X-Request-ID` も欠落する問題を
  修正**（#304）: 構造化 JSON レスポンス（`{"detail": ..., "request_id": ...}`）を返す
  `exception_handler` を追加。frontend にも構造化エラー型 `ApiError` と、クエリキャンセル
  時に実際の `fetch` を中断する `AbortSignal` 伝搬を追加。

## [0.2.6] - 2026-07-05

### Fixed

- **公開リポジトリの GitHub Code Quality 指摘（maintainability, note）を解消**:
  - `.github/scripts/tests/test_dora_metrics.py`: `unittest` を `import` と
    `from unittest import mock` の両方でインポートしていた（`py/import-and-import-from`）ため、
    `import unittest.mock` に統一。
  - `services/backend/python/alembic/` の `revision`/`down_revision`/`branch_labels`/
    `depends_on`（Alembic が実行時にモジュール属性として動的参照するため実際には必要）が
    `py/unused-global-variable` として検出されていた。CodeQL のルール説明が明記する
    `__all__` による意図的な公開の明示で解消。既存マイグレーション（`0001_create_items.py`）
    と、今後生成されるマイグレーションに効くよう `script.py.mako` テンプレートにも追加。
  - 残り1件（`alembic/env.py` の `models` 副作用インポート、`py/unused-import`）は
    Alembic の autogenerate に必要なインポートで削除できないため、公開リポジトリ側で
    false positive として dismiss 対応（コード変更なし）。
- **README.md の Release バッジが動作しない問題**: 公開用リポジトリ（`iwata-jawsug-jp/devcon`）は
  `publish-to-public.sh` の deploy key が git push 専用のため GitHub Release オブジェクトを作らず、
  タグのみ更新される。そのため shields.io の `github/v/release` バッジ（Releases API 参照）は
  「no releases found」と表示されていた。タグを参照する `github/v/tag` バッジに変更。

### Added

- **README.md に Security Policy バッジを追加**: `SECURITY.md`（#293）へリンクする静的バッジ。

## [0.2.5] - 2026-07-05

### Security

- **frontend の開発用依存関係にある Dependabot アラート対応**: `@lhci/cli`（Lighthouse CI、
  開発時のみ使用でプロダクションビルドには含まれない）が要求する `tmp@^0.1.0` /
  `uuid@^8.3.1` の範囲がパッチ済みバージョンを含まず、Dependabot が
  [`tmp` の Path Traversal（CVE-2026-44705, High）](https://github.com/iwata-jawsug-jp/devcon/security/dependabot/3)、
  [`uuid` のバッファ境界チェック漏れ（CVE-2026-41907, Medium）](https://github.com/iwata-jawsug-jp/devcon/security/dependabot/2)、
  [`tmp` のシンボリックリンク経由の任意ファイル書き込み（CVE-2025-54798, Low）](https://github.com/iwata-jawsug-jp/devcon/security/dependabot/1)
  を検知していた。`package.json` の `overrides` で `tmp@^0.2.6` / `uuid@^11.1.1` に強制固定し、
  `npm audit` の指摘を解消（lint/typecheck/test/`lhci healthcheck` で動作確認済み）。

## [0.2.4] - 2026-07-05

### Added

- **SECURITY.md**: 公開用リポジトリ（`iwata-jawsug-jp/devcon`）向けに脆弱性報告ポリシーを追加。
  GitHub の Private Vulnerability Reporting 経由での報告を案内する


## [0.2.3] - 2026-07-05


### Changed

- **チャット応答の既定言語を明記**（#289）: `CLAUDE.md`／`.github/copilot-instructions.md` に、
  対話の応答は原則日本語である旨を追記。成果物（コード・コミットメッセージ・PR/issue 本文等）
  の言語運用は変更しない。

## [0.2.2] - 2026-07-05

### Added

- **認証・認可（Cognito/JWT）の導入**（#41, Epic #46）: Cognito Hosted UI + JWT による
  認証・認可を追加。Terraform で User Pool・Resource Server（`api/items.read`/
  `api/items.write` スコープ）・パブリッククライアント（PKCE）を構築し、backend は
  `get_current_user`（JWT 署名/exp/iss/token_use/client_id 検証）と `require_scope`、
  frontend は `oidc-client-ts` ベースの `AuthStore`（トークンはメモリ限定保持）・
  ログイン/コールバック画面・ルーターガード・401 時の 1 回限りのリフレッシュ＋再試行を実装。
  既存 `items` ルーターに GET=読み取り/POST=書き込みスコープを適用。read/write を超える
  ロール・所有者ベース認可（→ #40）、WAF・レート制限（→ #44）、MFA 等はスコープ外として
  次の issue へ切り出し。
  - `.env.example` への Cognito サンプル値追記（#255）。
- **可観測性の整備**（Epic #42）: メトリクス・ダッシュボード・アラーム・トレース・SLO を
  一式追加。
  - **構造化ログ＋リクエスト相関 ID**（backend のみ）: JSON 1 行ログ（`JsonFormatter`）と、
    `X-Request-ID` を引き継ぐ/生成する `CorrelationIdMiddleware` を追加。
  - **分散トレーシング**: OpenTelemetry 計装＋ ADOT コレクタサイドカー→ AWS X-Ray を採用
    （ADR-0007）。`API_OTEL_TRACES_ENABLED`（dev 既定 false・prod 既定 true）で有効化し、
    無効時は追加コスト 0。JSON ログにも `trace_id`/`span_id` を付与。
  - **CloudWatch アラーム＋ SNS 通知**: ALB 5xx/レイテンシ、ECS CPU/メモリ、RDS CPU/
    接続数/空き容量の 7 アラームをメール通知（`alert_email` 未設定なら購読自体を作らない）。
  - **CloudWatch ダッシュボード**: 上記と同じ指標を 1 枚にまとめ、
    `terraform output cloudwatch_dashboard_url` で確認できる出力を追加。
  - **ヘルスチェックの DB 疎通確認＋ SLO/SLI 方針**: `GET /api/health` が `SELECT 1` で
    DB 疎通を確認し、失敗時は 503 を返すよう修正（従来は DB 全断でも 200 を返していた）。
    SLI（可用性＝ ALB 2XX 比率、レイテンシ＝ p95 TargetResponseTime）を
    `docs/infrastructure.md` に提案として記録。
- **負荷・性能テスト（k6）の導入**（#43）: `perf/k6/items-smoke.js` で health→list→get→
  create のシナリオを p95 レイテンシ・エラー率のしきい値で判定。毎週日曜＋手動実行のみで
  PR ごとには回さない。認証はスタブ化し、自前 API（ルーティング/バリデーション/DB 層）の
  性能に計測範囲を意図的に限定。
- **フロントエンドの DESIGN.md 仕様ビジュアルアイデンティティ文書**（#263）:
  `docs/frontend-design.md` を DESIGN.md 仕様（YAML トークン＋ prose）で追加し、既存の
  `brand-*` カラー・`font-sans` スタックから 1:1 で作成。
- **DESIGN.md からのテーマトークン自動生成**（#264）: `@google/design.md` を導入し、
  `docs/frontend-design.md` のトークンから `main.css` の `@theme` ブロックを生成する
  `make gen-design-tokens` を追加。`design:lint`（トークン整合性・WCAG コントラスト検証）を
  `make ci-frontend`/CI に組み込み。

### Security

- **deploy IAM ロールの権限をさらに縮小**（#45 follow-up）: `aws:RequestedRegion` 条件の
  追加（リージョン依存サービスのみ）、`elasticloadbalancing:*`/`application-autoscaling:*`/
  `cloudfront:*` の実使用アクションへの縮小、`iam:PassRole` を
  `iam:PassedToService=ecs-tasks.amazonaws.com` 条件付きの専用ステートメントへ分離。
  `infra/bootstrap/` は CI/CD 管理外のため、実 AWS への反映には人による手動
  `terraform apply` が必要。
- **plan ロールの state アクセスを dev キーのみに限定**（#45, #153）: `ci_plan` ロールが
  `ci_deploy` と同じ state バケット全体ポリシーを共有しており、PR を開くだけで理論上
  prod/sandbox の state ファイルを上書き・削除できた問題を修正。`ci_plan` 専用ポリシーを
  新設し、読み取りは dev 環境の state オブジェクトのみ、書き込みは dev のロックファイルのみに
  限定。
- **CloudFront オリジンを ALB でシークレットヘッダー検証**（#271）: ALB のセキュリティ
  グループは全 CloudFront ディストリビューションで共有される AWS 管理プレフィックス
  リストしか見ておらず、他人のディストリビューションからこの ALB へ直接到達できた問題を
  修正。CloudFront が `X-Origin-Verify` シークレットヘッダーを付与し、ALB リスナーは
  デフォルト拒否（403）＋ヘッダー一致時のみ転送するルールへ変更。

### Fixed

- **CI ツールのバージョン固定**（#272）: `setup-tflint`/`trivy-action`/checkov が
  `.devcontainer/Dockerfile` の固定バージョンと異なるバージョンで実行されていた問題を修正し、
  tflint 0.63.1 / trivy 0.71.2 / checkov 3.3.2 に統一。
- **frontend の生成型ドリフト**（#270）: `HealthResponse` が手書きのままで、生成済み
  `HealthStatus`（`database` フィールド追加済み）から乖離していた問題を修正。
- **mypy のスコープ不一致**（#269）: CI の `uv run mypy .` と `make backend-lint` の
  `mypy` が異なるファイル集合を検査していた（`alembic/` が CI のみ対象）問題を修正。

### Changed

- **`settings.local.json` がマージ確認ゲートを緩めうる点を明記**（#268）: `CLAUDE.md` の
  「main への無断マージ禁止」が permission 設定だけに依存するものではなく、標準的な運用
  ルールであることを明確化。


## [0.2.1] - 2026-07-04

### Added

- **DORAメトリクスの週次自動計測**（#237）: DORA Four Keysのうちデプロイ頻度・変更リード
  タイムを、追加インフラなしにGitHub Actions/GitHub APIのデータだけで自動集計する。
  - 計測定義（デプロイイベント・リードタイムの判定ロジック）をADR-0006として記録。
  - `.github/scripts/dora_metrics.py`（Python標準ライブラリのみ、単体テスト付き）で
    週次のデプロイ回数（backend/frontend/合算）とリードタイム（中央値・p85）を算出。
  - `.github/workflows/metrics-dora.yml` を `schedule`（週次）+ `workflow_dispatch`
    （任意期間指定）で実行し、job summaryへの出力と `docs/metrics/` への月次スナップ
    ショット追記を行う。`main` の必須ステータスチェックにより直接pushできないため、
    スナップショットはブランチpush + job summaryへのcompareリンク提示で、PRは手動で開く。
  - 直近4週間の移動平均をあわせて出力。
  - 公開用リポジトリへの変換公開時は `schedule` トリガーのみ除去する（継続的な自動実行は
    公開用には想定しないため）。
- **SDDの実装フェーズ運用規約**（#211, #212, #213）: 帳簿同期・design整合・非機能要件の
  所有について、実装フェーズ中の運用ルールを追加。
- **authn-authz spec の承認**: 認証・認可の要件・設計・タスクをspecとして追加し、現行の
  ディレクトリ構成に追従の上、tasksの承認を反映。

### Fixed

- **eslintとprettierの整形ルール衝突**（#214）: `eslint-config-prettier` を導入し、
  両ツールが競合する整形ルールを無効化。
- **`make ci-frontend` のLighthouse実行**（#215）: ローカルにChromeが無い環境向けに、
  LHCIの起動先をPlaywright同梱のchromiumへフォールバックする。



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
  （`docs/app-development.md` / `docs/infrastructure.md` / `docs/sandbox.md`）へ委譲。重複
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
  `env/sandbox.*.example`、`docs/sandbox.md`。sandbox 関連リソースは公開ミラー対象外。
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

[Unreleased]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.8...HEAD
[0.2.8]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.7...v0.2.8
[0.2.7]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.0...v0.2.1
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
