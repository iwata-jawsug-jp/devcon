# サービス置き換え実践ガイド（backend/frontend）

[ADR-0029](adr/0029-service-composition-change-criteria.md) が定めるのは「何を守るべきか」という
判断の原則である。本ガイドはその原則を前提に、`services/backend/python` や `services/frontend`
を別言語・フレームワークへ実際に置き換える際に「具体的にどのファイルの何を、どう直すか」を
実務手順として集約する。`docs/proposal/service-replacement-proposal.md`（提案書）の実装調査を
実践手順に再構成したもので、判断基準そのものは ADR-0029 を参照する。

診断・計画支援には [`.claude/skills/service-replacement-check/SKILL.md`](../.claude/skills/service-replacement-check/SKILL.md)
を使う。スキルの Mode A（reactive: 実装済みのものを契約と突き合わせて pass/fail を報告する）・
Mode B（proactive: 着手前にファイル/行単位のチェックリストを作る）は、本ガイドの手順と1対1で
対応する「検証」側であり、本ガイドは「実施」側にあたる。

## 影響範囲マップ

backend/frontend の実装を差し替える際に触る可能性がある契約点の一覧。`infra/*.tf` 側は
[#727](https://github.com/iwata-jawsug-jp/devcon/issues/727)（マージ済み）で Terraform 変数化済みのため、
以降の4項目は変数の既定値を変えるだけで対応でき、`infra/*.tf` 自体の編集は不要。

| 契約点                                | 場所                                                                                                   | 現在の値                                                                                                                                                     |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| API コンテナのリスンポート            | `infra/variables.tf:153`（`var.api_port`）／参照側 `infra/api.tf:106-107, 120, 127, 273, 339`（6箇所） | 既定 `8000`                                                                                                                                                  |
| ALB ヘルスチェックパス                | `infra/variables.tf:159`（`var.api_health_check_path`）／参照側 `infra/api.tf:126`                     | 既定 `/api/health`                                                                                                                                           |
| Cognito コールバックURL               | `infra/variables.tf:165`（`var.auth_callback_path`）／参照側 `infra/auth.tf:20`                        | 既定 `/callback`                                                                                                                                             |
| Cognito ログアウトURL                 | `infra/variables.tf:171`（`var.auth_login_path`）／参照側 `infra/auth.tf:21`                           | 既定 `/login`                                                                                                                                                |
| API 環境変数プレフィックス            | `infra/api.tf:276-289`（8個、リテラルなキー名としてハードコード。意図的に変数化していない）            | `API_*`                                                                                                                                                      |
| frontend ビルド環境変数プレフィックス | `reusable-app-deploy.yml:226-230`                                                                      | `VITE_*`                                                                                                                                                     |
| frontend ビルド出力ディレクトリ       | `reusable-app-deploy.yml:236-237`                                                                      | `dist/`                                                                                                                                                      |
| マイグレーション実行コマンド          | `reusable-app-deploy.yml:164`付近（`containerOverrides`）                                              | `["uv","run","--no-sync","alembic","upgrade","head"]`                                                                                                        |
| DB スキーマ権威                       | `Makefile:65-70`（`gen-schema`）                                                                       | Alembic（Python）が migrate、Go はスナップショットを `pg_dump` 経由で読むのみ                                                                                |
| ランタイムのネットワーク到達性        | `infra/network.tf`（NAT Gateway 不在）・`infra/endpoints.tf:62-70`                                     | private サブネットに internet 経路なし。到達可能なのは S3・ECR・CloudWatch Logs・Secrets Manager・**Cognito IDP**・（有効時）X-Ray の VPC エンドポイントのみ |

**変数化しないもの（意図的、ADR-0029 Decision 4）**: `API_*`/`VITE_*` の環境変数プレフィックス、
`dist/` のビルド出力先。これらは実装側（フレームワーク・言語）の規約であり、infra 側で変数化しても
実装が追従しなければ意味がない。

## backend 置き換え手順

### 1. スキーマ権威の移譲手順

`gen-schema`（`Makefile:65-70`）は4段構成で、Python 固有なのは2段目のみ。

```makefile
gen-schema: db-up migrate ## Snapshot the Alembic-migrated schema for Go's sqlc (Go never migrates; #639)
	docker compose exec -T db pg_dump -U app -d app --schema-only --no-owner --no-privileges \
		| sed '/^\\restrict /d; /^\\unrestrict /d' > $(CURDIR)/$(BACKEND_GO_DIR)/internal/db/schema.sql
	printf '%s\n' "$$(cat $(CURDIR)/$(BACKEND_GO_DIR)/internal/db/schema.sql)" > $(CURDIR)/$(BACKEND_GO_DIR)/internal/db/schema.sql.tmp
	mv $(CURDIR)/$(BACKEND_GO_DIR)/internal/db/schema.sql.tmp $(CURDIR)/$(BACKEND_GO_DIR)/internal/db/schema.sql
	cd $(BACKEND_GO_DIR) && sqlc generate
```

1. `db-up` — Postgres コンテナ起動（言語非依存）
2. `migrate` — Alembic マイグレーション実行（**唯一の Python 依存段**）
3. `pg_dump --schema-only` — マイグレーション済みスキーマのスナップショット取得（言語非依存）
4. `sqlc generate` — Go の sqlc がスナップショットから型付きクエリを生成（言語非依存）

`services/backend/go` は `Makefile:61-64` のコメントおよび `docs/app-development.md` に明記の通り、
スキーマを一切マイグレーションしない読み取り専用コンシューマとして設計されている。現在はこの構造に
より Alembic（Python）がスキーマの唯一の権威になっている。

`services/backend/python` を撤去し `services/backend/go`（または別言語）を唯一のバックエンドとして
残す場合、変更が必要なのは2段目の `migrate` ステップのみ——新バックエンド自身のマイグレーション
ツール（Go なら `golang-migrate` / `goose` / `atlas` 等、他言語ならその等価物）を呼び出す Make
ターゲットに差し替える。1・3・4段目はバックエンド言語に非依存であり変更不要。この疎結合は
`docs/proposal/service-replacement-proposal.md` §3.1 の調査で確認済みの実態であり、これから設計
する目標ではない。

原則: どのバックエンドをスキーマ権威とするかに関わらず、`migrate` ステップ（またはその置き換え先の
Make ターゲット）はその権威となるバックエンドのマイグレーションツールを呼び出す。それ以外の
バックエンドは全て `gen-schema` のスナップショットパイプライン経由の読み取り専用コンシューマの
ままであり、この関係自体は変更不要。

### 2. `reusable-backend-<lang>.yml` の新設／既存ワークフローとの役割分担

`.github/workflows/` には現在2つの backend ゲートワークフローが存在する。

| ファイル                  | 対象                                               | 命名                   | 備考                                                                                                                                            |
| ------------------------- | -------------------------------------------------- | ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `reusable-backend.yml`    | Python                                             | サフィックスなし       | ADR-0012 / #295。ci.yml と ci-sandbox.yml が共有する backend 品質ゲート。単一ソース化により両ワークフロー間の drift（#153 指摘7）を構造的に防ぐ |
| `reusable-backend-go.yml` | Go（`services/backend/go`、Lambda-only、ADR-0024） | `-go` サフィックスあり | ADR-0012 / #295 パターンを Go に適用。reusable-backend.yml の構造をミラーする                                                                   |

両ファイルとも `workflow_call` トリガーと `should_run` boolean input（デフォルト true）を持つ。
呼び出し側で `if:` によりジョブごとスキップするのではなく、ジョブは常に呼び出した上で内部で
`should_run` により早期終了させる——これはステータスチェックのコンテキスト名（Python:
`backend / check`、Go: `backend-go / check`）をスキップ状態に関わらず安定させるための ADR-0012 の
設計判断であり、変更してはならない。

`reusable-backend.yml` にサフィックスが無いのは Python が最初に導入されたバックエンドだったという
歴史的経緯にすぎず、模倣すべき命名規約ではない。第3の言語を追加する場合は `reusable-backend-go.yml`
に倣い `reusable-backend-<lang>.yml` を新設する。

Python を「追加」ではなく「置き換え」る場合は、以下いずれかを明示的に選択する。

- `reusable-backend.yml` → `reusable-backend-<newlang>.yml` にリネーム（推奨。命名規約の一貫性を
  保てる）
- サフィックスなしの名前を新実装がそのまま流用（`ci.yml` / `ci-sandbox.yml` のジョブ参照を書き
  換えずに済むが、命名の不整合を温存する）

いずれの場合も、新ワークフローは `workflow_call` トリガー・`should_run` input（ADR-0012 の
ステータスチェック名安定化）を備え、`ci.yml` と `ci-sandbox.yml` の両方から呼び出す（両ワーク
フロー間で重複定義しない、が ADR-0012 の要点）構成を維持する。

### 3. マイグレーションコマンドの `reusable-app-deploy.yml` `containerOverrides` への反映方法

`.github/workflows/reusable-app-deploy.yml` の `migrate` ジョブ（`needs: build`）は、新しく登録
されたタスク定義リビジョンを使い、コンテナのデフォルトコマンドをマイグレーション実行に上書き
した一回限りの Fargate タスクとして実行する（161-169行目）。

```bash
task_arn=$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$REV" \
  --launch-type FARGATE --count 1 \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=DISABLED}" \
  --overrides '{"containerOverrides":[{"name":"api","command":["uv","run","--no-sync","alembic","upgrade","head"]}]}' \
  --query 'tasks[0].taskArn' --output text)
echo "migration task: $task_arn"
aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$task_arn"
code=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task_arn" \
  --query 'tasks[0].containers[0].exitCode' --output text)
```

`containerOverrides` の `"name":"api"` は ECS タスク定義側のコンテナ名（`infra/api.tf` の
`container_definitions` でコンテナは文字通り `"api"` と命名されている）と一致しなければならない。

置き換え手順: `command` 配列を新実装のマイグレーション起動コマンド（例:
`["your-tool","migrate","up"]`）に差し替える。コンテナ名 `"api"` はインフラ側の識別子であり
実装言語に依存しないため、`infra/api.tf` 自体をリネームしない限り変更不要。`tasks-stopped`
待機後の exit code チェックがデプロイ失敗を検知する仕組みなので、新しいマイグレーションコマンドは
失敗時に非ゼロで終了する必要がある——これを満たさないとデプロイの安全装置が機能しなくなる。

### 4. OpenAPI抽出の標準化

`Makefile:54-59` の `gen-types` は各バックエンドにつき「サーバー起動なしで OpenAPI JSON を出力する
コマンド1本」を前提にしたパターンを取る。

```makefile
gen-types: ## Generate frontend TS types from both backends' OpenAPI schemas (Python + Go, #638)
	cd $(BACKEND_DIR) && uv run python -c "import json,sys; from api.main import app; json.dump(app.openapi(), sys.stdout)" > $(CURDIR)/$(FRONTEND_DIR)/openapi.python.json
	cd $(BACKEND_GO_DIR) && go run ./cmd/api openapi > $(CURDIR)/$(FRONTEND_DIR)/openapi.go.json
	cd $(FRONTEND_DIR) && npx --yes openapi-typescript openapi.python.json -o src/api/schema.python.ts
	cd $(FRONTEND_DIR) && npx --yes openapi-typescript openapi.go.json -o src/api/schema.go.ts
	rm -f $(FRONTEND_DIR)/openapi.python.json $(FRONTEND_DIR)/openapi.go.json
```

Python は `uv run python -c` のワンライナーで `app.openapi()` を直接呼び出す方式、Go は
`go run ./cmd/api openapi` という専用 CLI サブコマンド（内部で `huma.API.OpenAPI()` を呼ぶ、
`docs/app-development.md` 参照）を持つ方式——後者が新実装で踏襲すべきパターンである。Python
方式は先行実装ゆえの簡便な妥協であり、模範ではない。

`openapi-typescript` は各 JSON を個別の `schema.<lang>.ts` に変換し、単一 namespace への統合は
行わない。`docs/app-development.md`（392-395行目付近）: 「サービス別に出力ファイルを分割する方針
で型名衝突を回避（#638 で決定）...単一ファイルへの namespace 統合は行わない（2 サービスが独立に
進化するため）」。

新規/置き換えバックエンドの要件:

- サーバー起動なしで OpenAPI JSON を吐く専用コマンドを1本用意する（Go の `go run ./cmd/api openapi`
  パターンに倣う）
- `gen-types` に対応する2行（`openapi.<lang>.json` 中間ファイル生成 + `openapi-typescript` 実行）
  を既存パターンと同じ形で追加する
- Python を「置き換える」場合は Python の行を削除し、成果物名を付け替える。`schema.python.ts` を
  import しているフロントエンドコードの追従修正が必要——これは Makefile 変更だけでは完結しない、
  フロントエンド側のフォローアップ作業である

### 5. Dockerfile最低限契約チェックリスト

ADR-0029 Decision 項目5 / `docs/proposal/service-replacement-proposal.md` §4.4 に基づく、新
バックエンドの Dockerfile が満たすべき最低限の契約。`infra/variables.tf` への `var.api_port` /
`var.api_health_check_path` 追加（#727、マージ済み）後の状態を前提とする——以下の項目1・2は
リテラル値ではなくこれらの変数を参照する。

| #   | 契約                                                                                                                          | 根拠                                                                                                                                                                                                                                                              |
| --- | ----------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `0.0.0.0` で `var.api_port` を LISTEN する                                                                                    | ALB ターゲットグループがコンテナIPへ直接ルーティングするため、ループバックのみの待受では到達不能                                                                                                                                                                  |
| 2   | ヘルスチェックパス（`var.api_health_check_path`）は認証不要                                                                   | ALB のヘルスチェックリクエストは認証ヘッダを送らない。現行の `/api/health` は認証なしで実装されている                                                                                                                                                             |
| 3   | 依存関係はビルド時に完全解決する（ランタイムのネットワーク到達不可）                                                          | `infra/network.tf` に NAT Gateway が存在しないことを確認済み。private サブネットに internet 向け経路が無い                                                                                                                                                        |
| 4   | 実行時に到達できる AWS サービスは VPC エンドポイント経由のみ（S3・ECR・CloudWatch Logs・Secrets Manager・Cognito IDP・X-Ray） | `infra/endpoints.tf:62-70`。特に Cognito IDP（JWT 検証の JWKS 取得）はエンドポイントが無いと 504 タイムアウトの実害が過去に発生している（#369）                                                                                                                   |
| 5   | マイグレーションは `containerOverrides` でのコマンド差し替えに対応する                                                        | 本節3参照                                                                                                                                                                                                                                                         |
| 6   | `API_*` の環境変数キー名をそのまま読み取る                                                                                    | `infra/api.tf` はキー名がリテラルにハードコードされている: `API_DB_HOST`, `API_DB_PORT`, `API_DB_NAME`, `API_DB_USER`, `API_DB_PASSWORD`, `API_ENVIRONMENT`, `API_OTEL_TRACES_ENABLED`, `API_COGNITO_USER_POOL_ID`, `API_COGNITO_REGION`, `API_COGNITO_CLIENT_ID` |

### 6. 候補言語での検証結果

| 言語/フレームワーク                                                   | 適合度 | 注意点                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| --------------------------------------------------------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **TypeScript（Next.js / Nuxt.js、API Routes を backend として使用）** | 高     | 単一 Node プロセスが直接 HTTP を listen する点で Python/Go と同じモデル。`process.env.API_DB_HOST` 等をプレフィックス変換なしにそのまま読める（3候補中もっとも摩擦が少ない）。**要注意**: Next.js は既定で匿名テレメトリを起動時に外部送信しようとするため、NAT Gateway 不在の環境ではハング/タイムアウトの原因になり得る。`NEXT_TELEMETRY_DISABLED=1` の明記が必須。マイグレーションは Prisma Migrate / Drizzle Kit 等に対応する起動コマンドへの差し替えが必要 |
| **Java（Spring Boot 等）**                                            | 中     | ポート・ビルド時依存解決（Maven/Gradle）は標準的なマルチステージビルドで対応可能。**要注意**: `API_*` のリテラル環境変数名は Spring の慣習（`SPRING_*`、`application.yml`）と異なるため、`@ConfigurationProperties` 等でのマッピング層が必要。ヘルスチェックは Actuator の既定パスではなく `var.api_health_check_path` に独自実装する                                                                                                                           |
| **PHP（Laravel 等）**                                                 | 中〜低 | Composer でのビルド時依存解決は標準的。**要注意**: PHP は伝統的に nginx+php-fpm の2プロセス構成が多く、ECS Fargate が期待する「単一プロセスが直接 HTTP を listen する」モデルと食い違う。Swoole や RoadRunner 等の長時間実行サーバーを採用しないと、この契約を素直には満たせない                                                                                                                                                                                |

## frontend 置き換え手順

### 1. 単一スロット制約・Cognito Hosted UI移行の注意点

backend（`services/backend/<lang>/`）は Python と Go が並行共存する複数スロット構成だが、frontend
にこれに相当する言語/フレームワーク別のネスト構造はない。`services/frontend/` が唯一のフロント
エンドであり、置き換えは常に **in-place**（旧実装を削除し新実装に差し替える）で行う。backend の
Python + Go のように新旧フロントエンドを並行稼働させる選択肢は存在しない。

Cognito Hosted UI 連携は `services/frontend/src/auth/` に実装されている（`infra/auth.tf` 冒頭
コメント: 「Scope: infra provisioning only. JWT verification lives in the API... the Hosted UI
login/callback flow lives in the frontend (services/frontend/src/auth/)」）。infra 側は #727
マージ後、`infra/variables.tf` の2変数 `auth_callback_path`（既定値 `/callback`）・
`auth_login_path`（既定値 `/login`）でこのパスを外出しし、`infra/auth.tf` の
`cognito_callback_urls`/`cognito_logout_urls` local にフィードしている。

置き換え後の新フロントエンドは、`var.auth_callback_path`/`var.auth_login_path` に設定された値
（変更しなければ既定の `/callback`/`/login`）に一致するルートを実装し、OAuth2 Authorization Code

- PKCE フロー（`infra/auth.tf`: 「Public client (no secret — Authorization Code + PKCE
  only...)」）を完結させる必要がある。新フロントエンドのルーター規約が異なるパス構成を採る場合は、
  `infra/auth.tf` 自体ではなく `infra/variables.tf` の当該2変数を更新して整合させる——これは #727
  がまさに変数駆動にした契約点であり、この変数を変えるだけで済む設計になっている。

### 2. 品質ゲート不変条件の詳細

`reusable-frontend-<framework>.yml`（新フレームワーク用の reusable workflow）は、型チェック・
自動a11yチェック・パフォーマンス予算チェック・認証付きE2E の **4カテゴリすべて** を含まなければ
ならない。カテゴリ内でのツール置き換え（例: `vue-tsc` → `tsc`）は許容されるが、新フレームワークの
エコシステムのツール成熟度が低いことを理由にカテゴリごと落とすことは許容されない——それは簡素化
ではなく後退である。

現状（Vue/Vite 実装）のしきい値は `docs/app-development.md`（341〜356行付近）に以下の通り定義
されている。これは「置き換え後の frontend が満たすべき厳密な数値」ではなく、「今日の基準線は
この水準」という参考値として扱う。

| ゲート                    | しきい値                                                               | 計測方法                                                                                                     |
| ------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| backend カバレッジ        | `--cov-fail-under=90`（現状 ~99%）                                     | `pyproject.toml` の `addopts`（`pytest-cov`）。`uv run pytest` / `make backend-test` で自動適用              |
| frontend カバレッジ       | lines/statements 90%・functions 90%・branches 80%（現状 ~96%/92%/86%） | `vite.config.ts` の `test.coverage.thresholds`（`@vitest/coverage-v8`）。`npm test` で自動適用               |
| a11y                      | WCAG 2.0/2.1/2.2 の A+AA タグで違反ゼロ                                | `e2e/home.spec.ts` の `@axe-core/playwright` スキャン（Playwright e2e の一部として CI で実行）               |
| Core Web Vitals（lab）    | LCP ≤2.5s・CLS ≤0.1・Total Blocking Time ≤300ms（INP のラボ代替指標）  | `lighthouserc.json`（Lighthouse CI、`dist/` を `staticDistDir` で直接計測）                                  |
| Lighthouse カテゴリスコア | performance / accessibility とも ≥0.9                                  | 同上                                                                                                         |
| JS バンドル予算（gzip）   | script 400KB・stylesheet 100KB・total 600KB                            | `budget.json` を `scripts/check-bundle-budget.mjs` が読み、`dist/assets/` の実際の gzip サイズと突き合わせる |

4カテゴリと現状実装の対応:

- **型チェック** — 現状は `vue-tsc`（`reusable-frontend.yml` の型安全性ゲート）。置き換え後は
  対象フレームワークに応じた静的型チェッカー（Vue 以外の TS フレームワークなら `tsc` 等）を
  同等のCIゲートとして維持する。
- **自動a11yチェック** — 現状は `e2e/home.spec.ts` 内の `@axe-core/playwright` スキャン、
  Playwright e2e の一部として CI 実行。置き換え後もツール自体の差し替え（axe-core 相当への
  置換）は許容されるが、カテゴリの削除は不可。
- **パフォーマンス予算チェック** — 現状は Lighthouse CI（`lighthouserc.json`）＋
  `scripts/check-bundle-budget.mjs` が `budget.json` を `dist/assets/` の実サイズと突き合わせる
  構成。Lighthouse CI 自体はビルド済み静的出力を計測するフレームワーク非依存のツールであり、
  ビルド出力が `staticDistDir` で指し示せるディレクトリに収まる限り、フレームワーク差し替え後も
  ほぼそのまま流用できる可能性が高い。
- **認証付きE2E** — ADR-0008（`docs/adr/0008-live-smoke-playwright-project-with-disposable-cognito-user.md`）
  のライブスモークパターン: 実 Cognito Hosted UI ログイン＋認証付き書き込み（`POST /api/items`）
  ＋別コンテキストでの読み戻しを、実デプロイ環境に対して Playwright で駆動する
  （`services/frontend/e2e/live-smoke/`、`cd-app-sandbox.yml`/`cd-app.yml` の `smoke-test` job に
  組み込み済み）。このパターンは実ブラウザでデプロイ済み URL を操作する設計上フレームワーク
  非依存であり、フロントエンド置き換え後もほぼそのまま生き残る。ただし新フロントエンドの DOM が
  Playwright テストの対象セレクタを持たない場合はセレクタの追随修正が必要（パターン自体の書き
  直しは不要）。

### 3. デザイントークンパイプラインの扱い

`docs/frontend-design.md` の front matter（ファイル冒頭の YAML）が実際のデザイン値を保持しており、
これはフレームワーク非依存である。

```yaml
---
name: Origin Devcon Frontend
description: >
  Minimal brand layer on top of Tailwind v4 defaults...
colors:
  brand-50: 'oklch(0.97 0.02 250)'
  brand-500: 'oklch(0.55 0.18 250)'
  brand-600: 'oklch(0.48 0.18 250)'
  brand-700: 'oklch(0.4 0.18 250)'
typography:
  sans:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
---
```

生成パイプラインは Tailwind/Vite 依存であり、`Makefile` 72〜74行で定義されている。

```makefile
gen-design-tokens: ## Regenerate src/main.css's @theme block from docs/frontend-design.md (DESIGN.md)
	cd $(FRONTEND_DIR) && npm run design:gen-theme
	cd $(FRONTEND_DIR) && npx prettier --write src/main.css
```

`npm run design:gen-theme` は front matter を読み込み `src/main.css` の Tailwind v4 `@theme`
ブロックに書き込むスクリプト（`services/frontend/scripts/gen-design-tokens.mjs` 相当）を呼び出す。

`docs/frontend-design.md` の front matter の値そのものはフレームワーク置き換え時に変更してはなら
ない。変わるのは生成スクリプトの内部実装のみで、新フレームワーク/ライブラリが採用するスタイリング
機構（Tailwind を継続、あるいは CSS-in-JS・CSS Modules 等へ移行）に合わせて書き直す。これは
front-matter-as-source-of-truth パターンの廃止ではなく、生成スクリプトの**書き直し**である——値が
動かない以上、デザインの一貫性は置き換えを跨いで維持される。`Makefile` の `gen-design-tokens`
ターゲット自体は残し、内部で呼び出すコマンド（`npm run design:gen-theme`、または新フレームワーク
側の等価コマンド）だけを差し替える。

### 4. ビルド出力先・`VITE_*`環境変数プレフィックスの扱い

`.github/workflows/reusable-app-deploy.yml` の `frontend` job、`Build` ステップ（224〜230行）は
以下の環境変数をビルド時に注入している。Vite は `import.meta.env.VITE_*` をビルド時にインライン化
して静的バンドルに埋め込むため、実行時設定ではなくビルドステップへの環境変数として渡している。

```yaml
- name: Build
  env:
    VITE_COGNITO_USER_POOL_ID: ${{ inputs.cognito_user_pool_id }}
    VITE_COGNITO_REGION: ${{ env.AWS_REGION }}
    VITE_COGNITO_CLIENT_ID: ${{ inputs.cognito_client_id }}
    VITE_COGNITO_DOMAIN: ${{ inputs.cognito_domain }}
  run: npm run build
```

ビルド出力のデプロイは236〜237行。

```yaml
- name: Sync dist/ to S3
  run: aws s3 sync dist/ "s3://${{ inputs.web_bucket }}/" --delete
```

`VITE_*` は Vite 固有の規約であり、クライアントコードに公開する環境変数を `VITE_` プレフィックスの
ものだけに限定するのは、サーバー側シークレットの意図しない漏洩を防ぐための Vite のセキュリティ
境界設計であって、本プロジェクト独自の規約ではない。置き換え先フレームワークは独自の同等規約を
持つ（例: Next.js の `NEXT_PUBLIC_*`、Nuxt の `NUXT_PUBLIC_*` またはランタイム設定システム）。4つ
の環境変数名（`*_COGNITO_USER_POOL_ID`・`*_COGNITO_REGION`・`*_COGNITO_CLIENT_ID`・
`*_COGNITO_DOMAIN`）自体は概念的に変わらない（引き続き新フロントエンドがビルド時/実行時に必要と
する Cognito 設定）が、プレフィックスは `reusable-app-deploy.yml` の `Build` ステップ側で新フレーム
ワークの規約に合わせて更新する必要がある。

`dist/` は Vite の既定ビルド出力ディレクトリであり、新フレームワークの既定出力先が異なる場合
（例: Next.js の `.next/` + 静的エクスポート時の `out/`、あるいは独自の `build/`）、`Sync dist/ to
S3` ステップの同期元パスを合わせて更新する。なお `docs/proposal/service-replacement-proposal.md`
§5 のスコープ注記の通り、本手順は新フロントエンドが引き続き静的出力の SPA/SSG として
S3+CloudFront にデプロイ可能であることを前提としている。Next.js/Nuxt.js をライブサーバーとして
稼働させる SSR 構成が必要な場合は `infra/` 自体の再設計（ECS Fargate 等）が必要になり、同形置き
換えのスコープ外——別の、より大きな意思決定になる。

## 関連ドキュメント

- [ADR-0029](adr/0029-service-composition-change-criteria.md) — 本ガイドが実務手順に落とし込んで
  いる判断基準の親ADR
- [`.claude/skills/service-replacement-check/SKILL.md`](../.claude/skills/service-replacement-check/SKILL.md)
  — 本ガイドの手順に対応する診断・計画支援スキル（Mode A: 実装済みのものを検証、Mode B: 着手前の
  チェックリスト作成）
  本ガイドの元になった実装調査・提案書
- [ADR-0008](adr/0008-live-smoke-playwright-project-with-disposable-cognito-user.md) — 認証込み
  E2E（live-smoke）パターン
- [ADR-0024](adr/0024-adopt-go-as-second-backend-language.md) — backend 複数言語併存の実例
- [`app-development.md`](app-development.md) — 現行 backend/frontend の実装詳細・品質ゲートの
  しきい値
- issue #369 — Cognito IDP の VPC エンドポイント不在による JWKS 取得タイムアウトの実害
