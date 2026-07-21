# リポジトリ変数一覧

GitHub Actions の各ワークフロー（`ci.yml` / `cd-infra*.yml` / `cd-app*.yml`）が参照する
リポジトリ変数（`vars.*`。Settings → Secrets and variables → Actions → **Variables** タブ、
または `gh variable set` / `gh variable list` で操作）を、全カテゴリ横断で一望できる表に
まとめたもの。**「今どんな変数があるか」を確認したいときはまずここを見る。**
各変数の詳しい設計判断・登録手順は、表の「詳細」列が指す各ドキュメントを参照。

新しい変数を追加/変更/削除したときは、この一覧も忘れずに更新すること。
`make check-repo-vars`（`tools/script/check-repo-vars.sh`）で、workflow が実際に参照している
変数・この一覧の記載・実際の登録状況（`gh variable list`）の3者が一致しているかを機械的に
確認できる（ローカル/devcontainer 専用、CI では実行しない）。

## 1. bootstrap 配線用（4個・自動登録）

`infra/bootstrap/` の Terraform apply 直後、`tools/script/bootstrap.sh write` が自動登録する。
アプリ層（`infra/`）の `terraform plan`/`apply` が正しい state バケット・IAM ロールへ
たどり着くための配線。

| 変数名                | 参照する workflow・job                                                                                                                                    | 用途                                                                                           | 対応する Terraform output                          | 未設定/不一致時の挙動                                         |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | -------------------------------------------------- | ------------------------------------------------------------- |
| `AWS_TF_STATE_BUCKET` | `cd-infra.yml` / `cd-infra-sandbox.yml` / `cd-infra-verify.yml` / `cd-sandbox-cycle.yml`（各 `backend.hcl` 生成ステップ）                                 | Terraform state 用 S3 バケット名                                                               | `state_bucket_name`（bootstrap）                   | plan/apply が backend 初期化の段階で失敗                      |
| `AWS_PLAN_ROLE_ARN`   | `cd-infra.yml`（`plan`）                                                                                                                                  | 読み取り専用 `terraform plan` 用 OIDC ロール                                                   | `ci_plan_role_arn`（bootstrap）                    | OIDC 認証（`AssumeRoleWithWebIdentity`）が失敗                |
| `AWS_DEPLOY_ROLE_ARN` | `cd-app.yml` / `cd-app-sandbox.yml` / `cd-infra.yml`（`apply-dev`/`apply-prod`）/ `cd-infra-sandbox.yml` / `cd-infra-verify.yml` / `cd-sandbox-cycle.yml` | デプロイ用 OIDC ロール（sandbox/production 共用、[infrastructure.md](infrastructure.md) 参照） | `ci_deploy_role_arn`（bootstrap）                  | OIDC 認証が失敗                                               |
| `PROJECT_NAME`        | `cd-infra.yml` / `cd-infra-sandbox.yml` / `cd-infra-verify.yml` / `cd-sandbox-cycle.yml`                                                                  | tfvars/backend.hcl のプレースホルダ置換に使う project 名                                       | bootstrap の `project` 変数そのもの（output なし） | state ロックオブジェクトへの `s3:PutObject` が `AccessDenied` |

詳細: [infrastructure.md「ブートストラップ順序」](infrastructure.md#新規-aws-アカウントリージョンでの前提条件)

## 2. エリア別/オプトインスイッチ（5個・手動登録）

CI/CD の一部ジョブを一時停止/有効化するキルスイッチ。**極性が2種類ある**ので注意（下表の
「極性」列）。

| 変数名                | 参照する workflow・job                                            | 用途                                                                                                                      | 極性                         | 未設定時の挙動                                              |
| --------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | ---------------------------- | ----------------------------------------------------------- |
| `BACKEND_ENABLED`     | `ci.yml`（backend）/ `cd-app.yml`（build → migrate → deploy-api） | backend エリアの一時停止                                                                                                  | オプトアウト（`!= 'false'`） | 有効（デフォルト実行）                                      |
| `FRONTEND_ENABLED`    | `ci.yml`（frontend）/ `cd-app.yml`（frontend）                    | frontend エリアの一時停止                                                                                                 | オプトアウト                 | 有効                                                        |
| `INFRA_ENABLED`       | `ci.yml`（infra）/ `cd-infra.yml`（plan、手動 dispatch 含む）     | infra エリアの一時停止                                                                                                    | オプトアウト                 | 有効                                                        |
| `INFRA_APPLY_ENABLED` | `cd-infra.yml`（`apply-dev`/`apply-prod`）                        | apply 実行の二重鍵（`workflow_dispatch` 限定に加えて、対象は `environment` 入力で `dev`/`prod` を選択・デフォルト `dev`） | オプトイン（`== 'true'`）    | 無効（`apply-dev`/`apply-prod` スキップ）                   |
| `LIVE_SMOKE_ENABLED`  | `cd-app.yml`（`smoke-test`、第4のゲート）                         | 実ブラウザ E2E スモークテストの実行可否                                                                                   | オプトイン（`== 'true'`）    | 無効（`smoke-test` スキップ、デプロイ自体はブロックしない） |

詳細（設定手順・動作確認・注意事項）: [ci-cd-area-switches.md](ci-cd-area-switches.md)

## 3. 本番アプリ用（12個・プレフィックスなし・`write-cd-app-vars.sh`で自動登録）

`infra/`（アプリ層）を prod 向けに apply した後、`./tools/script/write-cd-app-vars.sh prod`
がその Terraform output を読んで登録する（カテゴリ1の `bootstrap.sh write` と同じ発想。
以前は手動で `gh variable set` を12回打っていた）。
**このリポジトリでは本番用の別インフラをまだ構築していないため、現状すべて未登録**
（`cd-app.yml` の `preflight` が未設定を検知し、以降のジョブをスキップする）。

| 変数名                       | 参照する workflow・job                                 | 用途                                                  | 対応する Terraform output                                                                    |
| ---------------------------- | ------------------------------------------------------ | ----------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `ECR_REPOSITORY`             | `cd-app.yml`（build）                                  | 本番 ECR リポジトリ名（レジストリと連結してタグ付け） | `ecr_repository_url`（末尾のリポジトリ名部分。フル URL ではなく名前のみを登録）              |
| `ECS_TASK_FAMILY`            | `cd-app.yml`（migrate, deploy-api）                    | 本番 ECS タスク定義ファミリー名                       | `ecs_task_family`                                                                            |
| `ECS_CLUSTER`                | `cd-app.yml`（migrate, deploy-api）                    | 本番 ECS クラスタ名                                   | `ecs_cluster_name`                                                                           |
| `ECS_SERVICE`                | `cd-app.yml`（deploy-api）                             | 本番 ECS サービス名                                   | `ecs_service_name`                                                                           |
| `PRIVATE_SUBNET_IDS`         | `cd-app.yml`（migrate）                                | migrate 用一回限り Fargate タスクのネットワーク配置   | `private_subnet_ids`                                                                         |
| `APP_SECURITY_GROUP_ID`      | `cd-app.yml`（migrate）                                | 同上                                                  | `app_security_group_id`                                                                      |
| `WEB_BUCKET`                 | `cd-app.yml`（frontend）                               | 本番フロントエンド配信用 S3 バケット                  | `web_bucket`                                                                                 |
| `CLOUDFRONT_DISTRIBUTION_ID` | `cd-app.yml`（frontend）                               | 本番 CloudFront 無効化対象                            | `cloudfront_distribution_id`                                                                 |
| `CLOUDFRONT_DOMAIN_NAME`     | `cd-app.yml`（smoke-test の base URL 構築）            | smoke-test が叩く本番公開 URL                         | `cloudfront_domain_name`                                                                     |
| `COGNITO_USER_POOL_ID`       | `cd-app.yml`（frontend の `VITE_*` 注入 + smoke-test） | Cognito Hosted UI 設定 / JWT 検証                     | `cognito_user_pool_id`                                                                       |
| `COGNITO_CLIENT_ID`          | `cd-app.yml`（frontend の `VITE_*` 注入）              | Cognito アプリクライアント ID                         | `cognito_user_pool_client_id`                                                                |
| `COGNITO_DOMAIN`             | `cd-app.yml`（frontend の `VITE_*` 注入）              | Cognito Hosted UI ドメインプレフィックス              | `cognito_hosted_ui_domain_prefix`（フル URL の `cognito_hosted_ui_domain` ではない点に注意） |

詳細: [infrastructure.md「`cd-app.yml`」](infrastructure.md)

## 4. sandbox 用（12個・`SANDBOX_` プレフィックス・`write-cd-app-vars.sh`で自動登録）

`cd-app-sandbox.yml` 専用。上記カテゴリ3と同じ11項目＋`SANDBOX_CLOUDFRONT_DOMAIN_NAME`に
`SANDBOX_` プレフィックスを付けたもの。`infra/` を sandbox 向けに apply した後、
`./tools/script/write-cd-app-vars.sh sandbox` が登録する。
**プレフィックスなしの名前では絶対に登録しないこと**
——`cd-app.yml`（本番用）が同名の変数を読むため、誤登録すると本番デプロイが sandbox の
リソースを誤って操作してしまう（issue #392 で実際に発生した障害）。
`write-cd-app-vars.sh` は環境ごとに接頭辞を切り替えるのでこの誤登録が起きない
（sandbox 実行時に接頭辞なしの名前へ書き込むことはない）。

| 変数名                               | 対応する本番用変数（カテゴリ3） |
| ------------------------------------ | ------------------------------- |
| `SANDBOX_ECR_REPOSITORY`             | `ECR_REPOSITORY`                |
| `SANDBOX_ECS_TASK_FAMILY`            | `ECS_TASK_FAMILY`               |
| `SANDBOX_ECS_CLUSTER`                | `ECS_CLUSTER`                   |
| `SANDBOX_ECS_SERVICE`                | `ECS_SERVICE`                   |
| `SANDBOX_PRIVATE_SUBNET_IDS`         | `PRIVATE_SUBNET_IDS`            |
| `SANDBOX_APP_SECURITY_GROUP_ID`      | `APP_SECURITY_GROUP_ID`         |
| `SANDBOX_WEB_BUCKET`                 | `WEB_BUCKET`                    |
| `SANDBOX_CLOUDFRONT_DISTRIBUTION_ID` | `CLOUDFRONT_DISTRIBUTION_ID`    |
| `SANDBOX_CLOUDFRONT_DOMAIN_NAME`     | `CLOUDFRONT_DOMAIN_NAME`        |
| `SANDBOX_COGNITO_USER_POOL_ID`       | `COGNITO_USER_POOL_ID`          |
| `SANDBOX_COGNITO_CLIENT_ID`          | `COGNITO_CLIENT_ID`             |
| `SANDBOX_COGNITO_DOMAIN`             | `COGNITO_DOMAIN`                |

`AWS_DEPLOY_ROLE_ARN`（カテゴリ1）はプレフィックスなしのまま sandbox/production 両方から
共用する——sandbox か production かは IAM 側の trust policy（assume 元のブランチ）で
区別しており、この変数自体は分ける必要がない。

詳細（#392 の経緯・GitHub Environments を採用しなかった理由）: [sandbox.md](sandbox.md)

## 5. dev 用（12個・`DEV_` プレフィックス・`write-cd-app-vars.sh`で自動登録・消費する workflow はまだ無い）

`infra/env/dev.tfvars` 向けに apply した dev 環境（安価・永続、sandbox のような使い捨てでは
ない）の Terraform output を、カテゴリ3・4と同じ形で `DEV_` プレフィックス付き登録できる
（`./tools/script/write-cd-app-vars.sh dev`）。**ただし現時点でこの `DEV_` 接頭辞を読む
workflow は存在しない**（`cd-app.yml` は接頭辞なし＝prod専用、`cd-app-sandbox.yml` は
`SANDBOX_` 専用）。dev 環境をアプリ層までデプロイする `cd-app-dev.yml` 相当の workflow を
将来追加する際に、その参照先としてあらかじめ登録しておける予定枠。

| 変数名                           | 対応する本番用変数（カテゴリ3） |
| -------------------------------- | ------------------------------- |
| `DEV_ECR_REPOSITORY`             | `ECR_REPOSITORY`                |
| `DEV_ECS_TASK_FAMILY`            | `ECS_TASK_FAMILY`               |
| `DEV_ECS_CLUSTER`                | `ECS_CLUSTER`                   |
| `DEV_ECS_SERVICE`                | `ECS_SERVICE`                   |
| `DEV_PRIVATE_SUBNET_IDS`         | `PRIVATE_SUBNET_IDS`            |
| `DEV_APP_SECURITY_GROUP_ID`      | `APP_SECURITY_GROUP_ID`         |
| `DEV_WEB_BUCKET`                 | `WEB_BUCKET`                    |
| `DEV_CLOUDFRONT_DISTRIBUTION_ID` | `CLOUDFRONT_DISTRIBUTION_ID`    |
| `DEV_CLOUDFRONT_DOMAIN_NAME`     | `CLOUDFRONT_DOMAIN_NAME`        |
| `DEV_COGNITO_USER_POOL_ID`       | `COGNITO_USER_POOL_ID`          |
| `DEV_COGNITO_CLIENT_ID`          | `COGNITO_CLIENT_ID`             |
| `DEV_COGNITO_DOMAIN`             | `COGNITO_DOMAIN`                |

`tools/script/check-repo-vars.sh` はこのカテゴリを「workflow参照なしでも正常」として扱う
（他カテゴリの「登録されているのにworkflowが参照していない＝orphan」警告からは除外）。

## 関連ドキュメント

- [infrastructure.md](infrastructure.md) — bootstrap 配線・本番アプリ用変数の設計判断、CI/CD 全体像
- [ci-cd-area-switches.md](ci-cd-area-switches.md) — エリア別/オプトインスイッチの設定手順・動作確認
- [sandbox.md](sandbox.md) — `SANDBOX_` プレフィックスの経緯（#392）
- issue [#392](https://github.com/iwata-jawsug-jp/devcon/issues/392) — sandbox/production 変数取り違えによる実障害
- [`tools/script/write-cd-app-vars.sh`](../tools/script/write-cd-app-vars.sh) — カテゴリ3〜5を
  対象環境の Terraform output から自動登録するスクリプト
