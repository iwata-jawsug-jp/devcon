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
Terraform 変数化済み（`infra/variables.tf` に `var.api_port` 等として切り出し済み）のため、
以降の4項目は変数の既定値を変えるだけで対応でき、`infra/*.tf` 自体の編集は不要。

| 契約点                                | 場所                                                                                                                        | 現在の値                                                                                                                                                     |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| API コンテナのリスンポート            | `infra/variables.tf:153`（`var.api_port`）／参照側 `infra/api.tf:106-107, 120, 127, 273, 339`（6箇所）                      | 既定 `8000`                                                                                                                                                  |
| ALB ヘルスチェックパス                | `infra/variables.tf:159`（`var.api_health_check_path`）／参照側 `infra/api.tf:126`                                          | 既定 `/api/health`                                                                                                                                           |
| Cognito コールバックURL               | `infra/variables.tf:165`（`var.auth_callback_path`）／参照側 `infra/auth.tf:20`                                             | 既定 `/callback`                                                                                                                                             |
| Cognito ログアウトURL                 | `infra/variables.tf:171`（`var.auth_login_path`）／参照側 `infra/auth.tf:21`                                                | 既定 `/login`                                                                                                                                                |
| API 環境変数プレフィックス            | `infra/api.tf:276-289`（10個: environment 9個 + secrets 1個。リテラルなキー名としてハードコード。意図的に変数化していない） | `API_*`                                                                                                                                                      |
| frontend ビルド環境変数プレフィックス | `reusable-app-deploy.yml:226-230`                                                                                           | `VITE_*`                                                                                                                                                     |
| frontend ビルド出力ディレクトリ       | `reusable-app-deploy.yml:236-237`                                                                                           | `dist/`                                                                                                                                                      |
| マイグレーション実行コマンド          | `reusable-app-deploy.yml:164`付近（`containerOverrides`）                                                                   | `["uv","run","--no-sync","alembic","upgrade","head"]`                                                                                                        |
| DB スキーマ権威                       | `Makefile` の `gen-schema` ターゲット                                                                                       | Alembic（Python）が migrate、Go はスナップショットを `pg_dump` 経由で読むのみ                                                                                |
| ランタイムのネットワーク到達性        | `infra/network.tf`（NAT Gateway 不在）・`infra/endpoints.tf:62-70`                                                          | private サブネットに internet 経路なし。到達可能なのは S3・ECR・CloudWatch Logs・Secrets Manager・**Cognito IDP**・（有効時）X-Ray の VPC エンドポイントのみ |

**変数化しないもの（意図的、ADR-0029 Decision 4）**: `API_*`/`VITE_*` の環境変数プレフィックス、
`dist/` のビルド出力先。これらは実装側（フレームワーク・言語）の規約であり、infra 側で変数化しても
実装が追従しなければ意味がない。

## 前提: devcontainerのツールチェーン確認

候補言語・フレームワークのビルド・実行に必要なツールチェーンが `.devcontainer/devcontainer.json` の
`features` に無い場合は追加する。Go を第二バックエンド言語として追加した際（ADR-0024）に
`ghcr.io/devcontainers/features/go:1` を追加した前例に倣い、[Dev Container Features](https://containers.dev/features)
から該当言語の feature を探して追加する。ここを見落とすと、本ガイドの以降の手順を試す前段階で
`make backend-setup` 等のコマンドがそもそも実行できずに詰まる。

## backend 置き換え手順

本節は同期REST（`services/backend/python` 相当、ECS Fargate上の常駐HTTPサーバー）の置き換えを
対象とする。非同期/イベント駆動ロール（`services/backend/go` 相当、Lambda、ADR-0024）は対象外
——本節のDockerfile契約6項目（後述）はいずれもHTTPサーバー・ALBヘルスチェック・
`containerOverrides` を前提としており、Lambdaハンドラーには当てはまらない。

同様に、契約#6の `API_*` 環境変数プレフィックス（`infra/api.tf` がECSタスク定義に注入するリテラルの
キー名群）も ECS Fargate 常駐サーバーを前提とした契約であり、非同期ワーカー（Lambda）が読むべき
環境変数の契約ではない。Lambda 用の環境変数は Lambda リソースを定義する Terraform 側で個別に注入する
構成になる（現状 `infra/` 配下に Lambda 関数リソースはまだ無く、`services/backend/go` 自体も
Lambda デプロイは未実施——今後 Lambda 化する際に新設する）ため、`API_*` の命名規則をLambda実装に
そのまま当てはめようとしない——本節の対象外という前段の注記と合わせて、環境変数契約についても
非該当であることを明示しておく。

### 1. スキーマ権威の移譲手順

`gen-schema` ターゲット（`Makefile`）は4段構成で、Python 固有なのは2段目のみ。

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

`services/backend/go` は `gen-schema` ターゲット直前のコメント（`Makefile`）および `docs/app-development.md` に明記の通り、
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

**スナップショット出力先について**: `gen-schema` ターゲット自体の出力パス
（`$(BACKEND_GO_DIR)/internal/db/schema.sql`）は Go/sqlc の消費先に決め打ちされている。
`services/backend/go` を撤去し、スナップショットを消費する読み取り専用コンシューマがGo以外に
なる（あるいは存在しなくなる）場合、この出力先をGo固有のパスのまま残す理由はない——
`services/backend/schema/schema.sql` のような、特定バックエンド言語のディレクトリに属さない
言語非依存な置き場所に変更し、`gen-schema` ターゲット・各コンシューマ側の読み込みパスの双方を
追従させる。読み取り専用コンシューマが存在しなくなる場合（スキーマ権威を持つバックエンド1つのみ
残す構成）でも、スナップショット自体は将来の3言語目追加時の起点になりうるため、ターゲット自体は
削除せず出力先のみ言語非依存な位置に変更しておくことを推奨する。

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

**Spring Boot（Spring Security併用）での罠——成功時にも非ゼロ終了しうる逆方向のケース**: 上記の
「失敗時に非ゼロで終了する必要がある」の裏返しとして、migrate専用モードの実装によっては**成功して
いるにもかかわらず非ゼロで終了する**罠がある。Spring Securityの`SecurityFilterChain`（`HttpSecurity`
が必要）を持つアプリで、migrate専用モードを`WebApplicationType.NONE`（Webレイヤーを起動しない
軽量モード）として実装すると、(1) Flywayなどのマイグレーション自体は正常に適用されるが、(2)
その直後に`SecurityConfig`の`filterChain`Bean生成が`HttpSecurity`（servlet専用）を要求して
ApplicationContextの初期化に失敗し、(3) 結果としてマイグレーションは成功しているのにexit 1で
終了する。`tasks-stopped`待機後の exit code チェックはこれを区別できないため、実際には成功して
いるマイグレーションを失敗と誤判定してデプロイパイプラインを止めてしまう。回避策は、migrate
モードも`WebApplicationType.NONE`ではなく`server.port=-1`（Web層はロードするが実TCPポートは
bindしない）で起動することである。こうすればSecurityを含む全レイヤーが通常通り初期化された上で
exit 0になる（`server.port=-1`自体は次節「4. OpenAPI抽出の標準化」の「Java（Spring Boot +
springdoc-openapi）での実現例」で使われているものと同じ起動オプションだが、そちらはOpenAPI抽出
目的、こちらはmigrateモードのApplicationContext初期化失敗回避が目的という別の用途である）。

### 4. OpenAPI抽出の標準化

`Makefile` の `gen-types` ターゲットは各バックエンドにつき「サーバー起動なしで OpenAPI JSON を出力する
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

生成された `schema.<lang>.ts` は Prettier（および同種のフォーマッタ）の整形対象から除外する
必要がある。`openapi-typescript` の生出力はインデント4スペース・ダブルクォートだが、本リポジトリの
Prettier 設定は2スペース・シングルクォートであり、両者が一致する保証はない（既存の
`schema.python.ts`/`schema.go.ts` は FastAPI/huma の生成結果がたまたま Prettier 設定に近い形式
だったため、これまで問題が表面化していなかっただけである）。除外していないと、コミット時に
pre-commit の prettier フックが生成ファイルを再整形し、その再整形後の内容が次回 `make gen-types`
再実行時の生の生成結果と食い違うため、`reusable-gen-types.yml` の drift check（`git diff
--exit-code`）が常に失敗する無限ループになる（#755）。

新しい言語を追加/置き換える際のチェックリストとして、`.pre-commit-config.yaml` の prettier フックの
`exclude` パターン（現状 `services/frontend/src/api/schema\.(python|go)\.ts` のような形）に新しい
`schema.<lang>.ts` を追加することを忘れないこと。この更新を怠ると上記の drift check 無限ループが
実際に発生する（itouhi/java-webapp2#1、#734 検証項目4で発見）。

**Java（Spring Boot + springdoc-openapi）での実現例**: springdoc-openapi の標準的な利用方法は
埋め込みサーバーを実際に起動する前提のものが多く、Go の `go run ./cmd/api openapi` のような
「サーバー起動なし」パターンは自明ではない。`server.port=-1` を指定して起動すると
`WebApplicationContext` は通常通り構築されるが実TCPポートはbindされないため、その状態で
`MockMvc`（`spring-test`）を使って springdoc の `/v3/api-docs` エンドポイントを in-process で
呼び出すことで、実HTTPクライアント・実ソケット無しに OpenAPI JSON を取得できる。この組み合わせは
Spring・springdoc いずれの公式ドキュメントにも記載がなく、Java を候補言語とする際に必ず踏む
ポイントである。

**プロパティ優先順位の罠**: 上記のエントリポイントを実DBに繋がず軽量に起動させるため、
`SpringApplicationBuilder.properties(Map.of("spring.datasource.url", "jdbc:h2:mem:..."))`
のようにプログラム的にプロパティを上書きしようとすると失敗する。`SpringApplicationBuilder.properties(...)`
で渡した値はSpring Bootのプロパティソース優先順位で**最低優先度**（デフォルト値相当）として
登録されるため、`application.yml` に書かれた値（本番用のPostgres接続文字列）に上書きされてしまい、
DBレス起動のつもりが実DBに接続しようとして失敗する。解決策は、オーバーライドしたい値を
`SpringApplicationBuilder.properties()` ではなくコマンドライン引数（`--spring.datasource.url=...`）
として渡すことである。コマンドライン引数は `application.yml` より優先順位が高いため確実に
上書きできる。

### 5. Dockerfile最低限契約チェックリスト

ADR-0029 Decision 項目5 / `docs/proposal/service-replacement-proposal.md` §4.4 に基づく、新
バックエンドの Dockerfile が満たすべき最低限の契約。`infra/variables.tf` への `var.api_port` /
`var.api_health_check_path` 追加後の状態を前提とする——以下の項目1・2は
リテラル値ではなくこれらの変数を参照する。

| #   | 契約                                                                                                                          | 根拠                                                                                                                                                                                                                                                              |
| --- | ----------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `0.0.0.0` で `var.api_port` を LISTEN する                                                                                    | ALB ターゲットグループがコンテナIPへ直接ルーティングするため、ループバックのみの待受では到達不能                                                                                                                                                                  |
| 2   | ヘルスチェックパス（`var.api_health_check_path`）は認証不要                                                                   | ALB のヘルスチェックリクエストは認証ヘッダを送らない。現行の `/api/health` は認証なしで実装されている                                                                                                                                                             |
| 3   | 依存関係はビルド時に完全解決する（ランタイムのネットワーク到達不可）                                                          | `infra/network.tf` に NAT Gateway が存在しないことを確認済み。private サブネットに internet 向け経路が無い                                                                                                                                                        |
| 4   | 実行時に到達できる AWS サービスは VPC エンドポイント経由のみ（S3・ECR・CloudWatch Logs・Secrets Manager・Cognito IDP・X-Ray） | `infra/endpoints.tf:62-70`。特に Cognito IDP（JWT 検証の JWKS 取得）はエンドポイントが無いと 504 タイムアウトの実害が過去に発生している（#369）                                                                                                                   |
| 5   | マイグレーションは `containerOverrides` でのコマンド差し替えに対応する                                                        | 本節3参照                                                                                                                                                                                                                                                         |
| 6   | `API_*` の環境変数キー名をそのまま読み取る                                                                                    | `infra/api.tf` はキー名がリテラルにハードコードされている: `API_DB_HOST`, `API_DB_PORT`, `API_DB_NAME`, `API_DB_USER`, `API_DB_PASSWORD`, `API_ENVIRONMENT`, `API_OTEL_TRACES_ENABLED`, `API_COGNITO_USER_POOL_ID`, `API_COGNITO_REGION`, `API_COGNITO_CLIENT_ID` |

**契約#3・#4はECS Fargate常駐サーバー前提——Lambda（非同期ワーカー）には同じ形で当てはまらない**:
上の表、特に契約#3（ビルド時依存解決）と契約#4（VPCエンドポイント経由のみ到達可能）は、本節が
対象とする「ECS Fargate上の常駐HTTPサーバー」（冒頭参照）を暗黙の前提にしている。`services/backend/go`
相当の非同期/イベント駆動ロール（Lambda、ADR-0024）は本節の対象外だが、置き換え先をLambdaで実装
する場合にこの前提の違いを見誤ると、#369と同種の「実デプロイでのみ顕在化するタイムアウト」を
再現しうる（itouhi/java-webapp2#1、devcon#734で発見、#758）。

| 観点                 | ECS Fargate（常駐サーバー、本節の対象）                                    | Lambda（非同期ワーカー、ADR-0024、本節の対象外）                                                                                                                                          |
| -------------------- | --------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| イベント受信経路     | アプリ自身が契約#1でリスンし、ALBがVPC内のコンテナIPへ直接ルーティングする | SQS→Lambdaのイベント配信はLambdaサービス自身（AWS管理側）のイベントソースマッピング/ポーラーが行う。**Lambda関数のコード自体はメッセージを「受信」するためにVPC経路を必要としない**       |
| VPCアタッチの要否    | 常時必須（ALBがVPC内のコンテナIPへ到達するため）                          | 任意。RDS Postgres等プライベートサブネット内のリソースへ到達する必要がある場合のみVPCアタッチする                                                                                        |
| 契約#4の該当性       | 常に該当                                                                    | VPCアタッチしない場合は非該当（イベント受信はAWS管理のネットワークで完結する）。VPCアタッチする場合のみ、ECS同様に「実行時に到達できるAWSサービスはVPCエンドポイント経由のみ」が適用される |

**VPCアタッチしたLambdaワーカーがSQSを直接呼び出す場合は`sqs`エンドポイントが別途必要**:
VPCアタッチしたLambdaワーカーが、メッセージ処理完了後のバッチ削除など、SQS自体をAPI呼び出しする
場合は契約#4がそのまま適用される。現状の`infra/endpoints.tf`のインターフェースエンドポイント
（`interface_endpoints`）はECR(api/dkr)・CloudWatch Logs・Secrets Manager・Cognito IDP・
（`var.otel_traces_enabled`有効時のみ）X-Rayのみで、`sqs`（`com.amazonaws.<region>.sqs`）は
含まれない（本ガイド冒頭の「影響範囲マップ」参照）。この場合は`infra/endpoints.tf`の
`interface_endpoints`に`sqs`を追加する必要がある。

### 6. 候補言語での検証結果

| 言語/フレームワーク                                                   | 適合度 | 注意点                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| --------------------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **TypeScript（Next.js / Nuxt.js、API Routes を backend として使用）** | 高     | 単一 Node プロセスが直接 HTTP を listen する点で Python/Go と同じモデル。`process.env.API_DB_HOST` 等をプレフィックス変換なしにそのまま読める（3候補中もっとも摩擦が少ない）。**要注意**: Next.js は既定で匿名テレメトリを起動時に外部送信しようとするため、NAT Gateway 不在の環境ではハング/タイムアウトの原因になり得る。`NEXT_TELEMETRY_DISABLED=1` の明記が必須。マイグレーションは Prisma Migrate / Drizzle Kit 等に対応する起動コマンドへの差し替えが必要                                                                                                                                                                                                                                                                                                                                                     |
| **Java（Spring Boot 等）**                                            | 中     | ポート・ビルド時依存解決（Maven/Gradle）は標準的なマルチステージビルドで対応可能。**要注意**: `API_*` のリテラル環境変数名は Spring の慣習（`SPRING_*`、`application.yml`）と異なるため、`@ConfigurationProperties` 等でのマッピング層が必要。ヘルスチェックは Actuator の既定パスではなく `var.api_health_check_path` に独自実装する。OpenAPI JSON抽出は§4「OpenAPI抽出の標準化」の Java 向け実現例（`server.port=-1` + `MockMvc` の in-process 呼び出し）を参照。マイグレーションにFlywayを使う場合（Spring Boot 3.3系）は `flyway-core` だけでなく `flyway-database-postgresql` を明示的に依存追加しないとPostgreSQL用のDB検出に失敗する。また `maven-compiler-plugin` の版数を明示的にpinしないと、古い既定バージョンでは `maven.compiler.release` の指定が無視され意図したJavaバージョンでコンパイルされない。 |
| **PHP（Laravel 等）**                                                 | 中〜低 | Composer でのビルド時依存解決は標準的。**要注意**: PHP は伝統的に nginx+php-fpm の2プロセス構成が多く、ECS Fargate が期待する「単一プロセスが直接 HTTP を listen する」モデルと食い違う。Swoole や RoadRunner 等の長時間実行サーバーを採用しないと、この契約を素直には満たせない                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |

## frontend 置き換え手順

### 1. 単一スロット制約・Cognito Hosted UI移行の注意点

backend（`services/backend/<lang>/`）は Python と Go が並行共存する複数スロット構成だが（同一言語が複数役割を担う場合の命名は [ADR-0004](adr/0004-rename-services-by-role-and-nest-backend-by-language.md) 追記を参照）、frontend
にこれに相当する言語/フレームワーク別のネスト構造はない。`services/frontend/` が唯一のフロント
エンドであり、置き換えは常に **in-place**（旧実装を削除し新実装に差し替える）で行う。backend の
Python + Go のように新旧フロントエンドを並行稼働させる選択肢は存在しない。

Cognito Hosted UI 連携は `services/frontend/src/auth/` に実装されている（`infra/auth.tf` 冒頭
コメント: 「Scope: infra provisioning only. JWT verification lives in the API... the Hosted UI
login/callback flow lives in the frontend (services/frontend/src/auth/)」）。infra 側は
Terraform 変数化済みであり、`infra/variables.tf` の2変数 `auth_callback_path`（既定値 `/callback`）・
`auth_login_path`（既定値 `/login`）でこのパスを外出しし、`infra/auth.tf` の
`cognito_callback_urls`/`cognito_logout_urls` local にフィードしている。

置き換え後の新フロントエンドは、`var.auth_callback_path`/`var.auth_login_path` に設定された値
（変更しなければ既定の `/callback`/`/login`）に一致するルートを実装し、OAuth2 Authorization Code

- PKCE フロー（`infra/auth.tf`: 「Public client (no secret — Authorization Code + PKCE
  only...)」）を完結させる必要がある。新フロントエンドのルーター規約が異なるパス構成を採る場合は、
  `infra/auth.tf` 自体ではなく `infra/variables.tf` の当該2変数を更新して整合させる——これは
  まさに Terraform 側が変数駆動にした契約点であり、この変数を変えるだけで済む設計になっている。

**注意: 本ガイド・ADR-0029に明記されていない暗黙結合フックが存在しうる。** `.pre-commit-config.yaml`
には、特定ファイルパス/フォーマットに `files:` 正規表現で暗黙結合したローカルフックが存在する場合が
あり、それらはこのガイドにも ADR-0029 にも列挙されていない。実例が `check-oauth-scopes`
（`.pre-commit-config.yaml` 99〜107行目付近、#438由来）で、`infra/auth.tf` の Cognito リソース
サーバースコープと `services/frontend/src/auth/oidcConfig.ts` の `const scope = '...'` 文字列の
整合性を突き合わせるが、`files:` が両ファイルの現在のパスにしかマッチしない設計になっている。
frontend を本ガイドどおりに再構築してファイル構成やスコープの変数定義方法（例: `const scope = '...'`
文字列 → `scopes: [...]` 配列）を変えると、このフックは単に**マッチしなくなるだけで、エラーも警告も
出さずに無効化される**——「認証スコープの整合性チェックが壊れたことに誰も気づかない」という静かな
退行を招く。このパターンは `check-oauth-scopes` に限らない一般的な罠なので、frontend/backend の
構成を変える置き換えでは `.pre-commit-config.yaml` の全ローカルフックの `files:` パターンを棚卸しし、
移動・改名・フォーマット変更した対象ファイルに追従しているか（マッチし続けるか）を確認すること。

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

現行の生成スクリプト（`services/frontend/scripts/gen-design-tokens.mjs`）のソースを読まずに再現
しようとすると見落としやすい出力フォーマットの詳細が3点ある。書き直す新スクリプトも、値だけでなく
この3点の挙動を踏襲する必要がある。

- **色のOKLCH→hex正規化**: `docs/frontend-design.md` の front matter では色を OKLCH
  （例: `oklch(0.55 0.18 250)`）で記述するが、`designmd export --format css-tailwind` の生成結果は
  常に hex に正規化される。これは意図した挙動であり、生成後の `main.css` を hex から OKLCH に
  手で戻す必要はない。
- **フォントスタックの引用符除去**: エクスポータは `--font-*` の値を丸ごとダブルクォートで囲むが、
  これは単一ファミリー名には正しくてもカンマ区切りのフォールバックリストには不適切
  （ブラウザがフォールバックチェインではなく1つのリテラルな引用符付き文字列として解釈してしまう）。
  そのため `gen-design-tokens.mjs` は生成結果に対し `--font-[\w-]+:\s*"([^"]*)"` 相当の正規表現で
  引用符を剥がす後処理を行っている。
- **`design-tokens:start`/`:end` マーカー構文**: 生成結果は `src/main.css` 内の
  `/* design-tokens:start */` と `/* design-tokens:end */` という2つのコメント行に挟まれた区間にのみ
  書き込まれる（両マーカー行自体は保持されたまま、間の内容だけが置き換わる）。新スクリプトでも
  同じ2マーカー間だけを書き換える方式を維持し、マーカー行そのものを生成結果に含めたり削除したり
  しないこと。

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

### 5. `services/frontend/CLAUDE.md` の規約: load-bearingなものと実装固有の慣習の区別

`services/frontend/CLAUDE.md` に列挙されている規約（例: `vite-ssg` によるプリレンダー、
`useXxxQuery()` 経由でのみサーバー状態を取得する TanStack Query パターン、Pinia でのクライアント
状態管理）は、本ガイド・ADR-0029が定める infra/CI 契約点（環境変数プレフィックス、ヘルスチェック
パス等）とは異なり、「どれが置き換え後も維持すべき契約で、どれが単なる実装上の選択だったか」の
線引きがガイド本文のどこにも明示されていない。ガイドだけを頼りに置き換えると、これらの規約は
そもそも参照されないため再現されない——ガイドに正しく従った結果として規約が失われる、という
判断保留のまま進みやすい箇所である。

現時点でこの区別自体を体系的に棚卸しする作業は本ガイドのスコープ外とし、置き換え作業者は
「本ガイド・ADR-0029に明記された契約点（`infra/*.tf` 変数、`reusable-app-deploy.yml` の環境変数、
品質ゲート4カテゴリ等）は維持必須、それ以外の `services/frontend/CLAUDE.md` 記載の実装パターンは
新フレームワークの慣習に合わせて置き換えてよい実装上の選択」という原則で都度判断する。この原則が
実際に機能しない粒度の規約が見つかった場合は、本ガイドへの追記または新規issueとして切り出す。

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
