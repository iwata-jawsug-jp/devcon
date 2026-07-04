# インフラ・CI/CD 開発ガイド

`infra/`（Terraform）と `.github/workflows/`（GitHub Actions）の構造・運用。
全体のアーキテクチャは [`../CLAUDE.md`](../CLAUDE.md) を参照。

## 全体像

![インフラ論理構成図](images/infra-architecture.drawio.svg)

> 図は draw.io で編集可能な `*.drawio.svg`（`docs/images/infra-architecture.drawio.svg`）。
> draw.io で開くと SVG に埋め込まれた図を直接編集できる。以下はテキスト版。

```
infra/bootstrap/   ── 初回のみ・ローカル state ──▶  state バケット（S3 ネイティブロック）
                                                    GitHub OIDC プロバイダ / CI IAM ロール
        │ （上記が CI とリモート state の土台になる）
        ▼
infra/（アプリ層） ── リモート state ──▶  web=S3+CloudFront / api=ECR+ECS / shared=VPC ほか
        ▲
        │ cd-infra.yml（plan/apply）が管理
GitHub Actions ── OIDC でロール引受（長期キーなし）
```

リージョン既定は `ap-northeast-1`。全リソースは provider の `default_tags` でタグ付け。

---

## Terraform 2 層構成

### 1. `infra/bootstrap/`（初回のみ・ローカル state）

パイプラインが動く**前に一度だけ**ローカル state で適用する土台。`cd-infra.yml` の管理対象外。

作成するもの:

- **S3 state バケット**（バージョニング + SSE + public-access-block + 非 HTTPS を拒否する
  TLS 限定バケットポリシー）。
  ロックは **S3 ネイティブロック**（`use_lockfile`）を使用し、DynamoDB は不要
  （ロックは state と同じバケットの `<key>.tflock` オブジェクト）。
- **GitHub OIDC プロバイダ**（`token.actions.githubusercontent.com`, aud `sts.amazonaws.com`）
- **CI 用 IAM ロール 2 つ**
  - `*-ci-plan` … PR 用の読み取り専用（plan）。AWS 管理の `ReadOnlyAccess`。
  - `*-ci-deploy` … main / `production` 用のデプロイ。**最小権限化済み**（#45）: 以前は
    `PowerUserAccess` だったが、`infra/*.tf` が実際に宣言するリソース種別（EC2 ネットワーク・
    ECS・ECR・ELB・RDS・S3・CloudFront・CloudWatch Logs・Application Auto Scaling）ごとに
    スコープした inline policy（`ci_deploy_network`/`ci_deploy_compute`/
    `ci_deploy_storage_cdn`/`ci_deploy_data`、`bootstrap/main.tf`）に置き換えた。IAM 自体の
    権限（ECS タスクロールの作成・PassRole）は元から `${var.project}-*` ロール名に
    スコープ済み（`ci_deploy_iam`）。
    **注意**: `bootstrap/` は `cd-infra.yml` の管理対象外 — このポリシー変更は
    CI では自動適用されない。ローカルで `cd infra/bootstrap && terraform apply` を
    実行して初めて反映される。CloudTrail 等の実アクセス履歴からではなく静的なリソース種別
    分析から導出したため、初回 apply/デプロイで `AccessDenied` が出た場合は
    該当アクションを追加すること。
  - いずれも assume-role を OIDC の `sub`/`aud` 条件（org/repo）で制限

> **Terraform バージョン要件**: bootstrap 層は `>= 1.9`、アプリ層は `>= 1.11`
> （S3 ネイティブロック `use_lockfile` のため）。ローカルで bootstrap / マイグレーションを
> 触る場合は **1.11 以上**を入れておけば両層で通る（CI/CD の workflow は `1.13.0` に統一）。

```bash
cd infra/bootstrap
terraform init                 # ローカル state（backend ブロックなし）
terraform apply                # 一度だけ
terraform output               # state バケット名 / ロール ARN を控える
```

出力した値を後段に配線する:

- `state_bucket_name` → **リポジトリ変数** `AWS_TF_STATE_BUCKET`。`cd-infra.yml` は
  各ジョブ冒頭で `env/<env>.backend.hcl.example` の `REPLACE-ME-tfstate` をこの値に
  置換して `backend.hcl` を生成し（`*.tfvars` は `.example` をコピー）、init/plan する。
  `backend.hcl` / `*.tfvars` は git-ignored のまま CI 実行時に組み立てる方式で、秘密値は
  git にもログにも入らない（バケット名は非機密、RDS マスターパスワードは RDS 管理＝
  Secrets Manager で state/tfvars に出ない）。ローカルで触る場合は同様に `.example` から
  `infra/env/<env>.backend.hcl` を自前で穴埋めする。
- `ci_plan_role_arn` / `ci_deploy_role_arn` → **リポジトリ変数**（`cd-infra.yml` /
  `cd-app.yml` が参照）。`gh` で登録する例:

```bash
gh variable set AWS_TF_STATE_BUCKET --body "$(terraform -chdir=infra/bootstrap output -raw state_bucket_name)"
gh variable set AWS_PLAN_ROLE_ARN   --body "$(terraform -chdir=infra/bootstrap output -raw ci_plan_role_arn)"
gh variable set AWS_DEPLOY_ROLE_ARN --body "$(terraform -chdir=infra/bootstrap output -raw ci_deploy_role_arn)"
```

> **これら 3 変数を登録するまで `cd-infra.yml` の plan/apply は失敗する**（下記「bootstrap
> 適用前の CI 挙動」を参照）。

### 2. アプリ層（`infra/*.tf`・リモート state）

`cd-infra.yml` が管理。`backend.tf` は **部分設定**（`backend "s3" {}`）で、env ごとの
hcl を渡して初期化する。

> ファイル名・リソース論理名の `api`/`web` は `services/backend/python` / `services/frontend`
> という**アプリ側のディレクトリ名とは独立**（[ADR-0004](adr/0004-rename-services-by-role-and-nest-backend-by-language.md)）。
> リソース名を追従させるとリソースの再作成（replace）を招くため、意図的に変更していない。

| ファイル                                                                      | 内容                                                                                                                                                                             |
| ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `main.tf`                                                                     | レイヤ共通の locals（`name_prefix`）・データソース（caller identity / region）                                                                                                   |
| `network.tf`                                                                  | VPC（2 AZ・public/private subnet・IGW）、app SG / db SG。TODO: NAT ゲートウェイ（private subnet の egress 用）                                                                   |
| `endpoints.tf`                                                                | ECR / CloudWatch Logs / Secrets Manager 向け VPC インターフェースエンドポイント + S3 ゲートウェイエンドポイント（NAT なしで Fargate タスクがプライベートリンク経由でアクセス）   |
| `db.tf`                                                                       | **RDS for PostgreSQL**（private subnet・暗号化・非公開・Secrets Manager マネージド認証）                                                                                         |
| `web.tf`                                                                      | SPA 配信（S3 + CloudFront（OAC）+ セキュリティヘッダーポリシー）。TODO: カスタムドメイン用の ACM 証明書 / Route53（`var.domain_name` 設定時のみ）                                |
| `api.tf`                                                                      | ECR リポジトリ + ECS Fargate（クラスタ・タスク定義・サービス）+ ALB + Application Auto Scaling（CPU/メモリのターゲット追跡、#44）。代替案としてコメントに Lambda + API GW も記載 |
| `shared.tf`                                                                   | CloudWatch ロググループ、ECS タスク実行ロール / タスクロール（IAM）                                                                                                              |
| `providers.tf` / `versions.tf` / `variables.tf` / `outputs.tf` / `backend.tf` | 共通定義                                                                                                                                                                         |

### データベース（RDS for PostgreSQL）

- `db.tf` の RDS は **private subnet** に置き、`db` セキュリティグループで **app SG からの
  5432 のみ**許可（パブリックアクセス不可）。
- マスター認証情報は **RDS マネージド**（`manage_master_user_password = true` → Secrets
  Manager）。Terraform state にパスワードを残さない。ECS タスクには接続情報＋シークレット
  ARN を注入する（`api.tf` 参照）。
- 保管時暗号化・自動バックアップ・IAM 認証・Performance Insights を有効化。multi-AZ /
  削除保護 / final snapshot は env 変数（dev は安価、prod は堅牢）。
- **マイグレーションの適用は CD（`cd-app.yml` の専用ジョブ）**が担う（下記）。

### API（ECS Fargate）のオートスケール（#44）

`api.tf` の `aws_appautoscaling_target` + `aws_appautoscaling_policy`（CPU / メモリの
target tracking、2本）。`aws_ecs_service.api` は `desired_count` を `lifecycle.ignore_changes`
で無視しているため、初期作成後は Application Auto Scaling とデプロイパイプライン
（`cd-app.yml` の `update-service`）が実際の値を管理する。

- `ecs_min_capacity` / `ecs_max_capacity` / `ecs_cpu_target_value` / `ecs_memory_target_value`
  （`variables.tf`）で調整。**dev は `min == max == 1` でスケール実質無効化**、
  **prod は `min=1, max=4` で実際にスケールする**（`env/{dev,prod}.tfvars.example` 参照）。
  スケールアウトは 60 秒、スケールインは 300 秒のクールダウン（頻繁な増減を避ける）。
- ALB リクエスト数ベースのターゲット追跡（`ALBRequestCountPerTarget`）は未導入。CPU/メモリで
  不足する場合に追加を検討。

```bash
# リモート state で初期化（env ごとの backend hcl を指定）
make tf-init BACKEND=env/dev.backend.hcl
# もしくは:
cd infra && terraform init -backend-config=env/dev.backend.hcl

make tf-plan      # infra/env/dev.tfvars があれば自動で -var-file
make tf-validate
make tf-lint
make security     # Trivy + Checkov
```

### env ごとの設定ファイル

`*.example` のみコミットし、実ファイル（`*.tfvars` / `*.backend.hcl`）は git-ignored。

```
infra/env/
├── dev.tfvars.example          # project/environment/aws_region など
├── prod.tfvars.example
├── dev.backend.hcl.example     # bucket/key/region/use_lockfile/encrypt
└── prod.backend.hcl.example
```

```bash
cp infra/env/dev.backend.hcl.example infra/env/dev.backend.hcl   # bootstrap 出力で穴埋め
cp infra/env/dev.tfvars.example      infra/env/dev.tfvars
```

### 規約

- 2 スペースインデント、`terraform fmt`（`make tf-fmt`）。
- タグは provider の `default_tags` で一括付与（個別リソースに手書きしない）。
- state はリモート（S3 + ネイティブロック `use_lockfile`）。`*.tfstate` はコミットしない。

---

## CI/CD（GitHub Actions）

`.github/workflows/` に配置。CI は Makefile / pre-commit と同じゲートを通すので
「ローカルで green == CI で green」。

| ワークフロー   | トリガー         | 役割                                                    |
| -------------- | ---------------- | ------------------------------------------------------- |
| `ci.yml`       | PR / main push   | 変更パスのみ per-service で検証                         |
| `cd-infra.yml` | PR / 手動        | Terraform plan（PR）/ apply（手動 `workflow_dispatch`） |
| `cd-app.yml`   | main push / 手動 | アプリのビルド & デプロイ                               |

### `ci.yml`

パスフィルタで、変更のあったサービスのジョブだけ実行する。

- **api**: `uv sync` → ruff → mypy → pytest
- **web**: `npm ci` → eslint → `vue-tsc --noEmit` → vitest → build（→ Playwright e2e）
- **infra**: `terraform fmt -check` → `init -backend=false` → validate → tflint → checkov + trivy

### `cd-infra.yml`

- **PR**: `terraform plan` を実行し、結果を PR にコメント（plan ロール）。
- **apply（手動）**: `workflow_dispatch` で手動実行する `terraform apply`（deploy ロール・
  `TF_ENV=prod`）。private repo ＋現プランでは GitHub Environment の required reviewers が
  使えないため、**main マージでは自動 apply せず**、手動実行そのものをゲートとする
  （`production` 環境はデプロイ記録用）。

#### 承認ゲートの恒久化（Enterprise / Team / Pro へ移行、または public 化した場合）

GitHub Environment の保護ルール（**required reviewers** / wait timer / deployment branch policy）は
**public リポジトリでは無料**、**private リポジトリでは Pro / Team / Enterprise** で利用できる。
現状は private ＋無料プランのため API が `422`（`billing plan ... required reviewers protection
rule`）を返し設定できないので、上記のとおり apply を手動 `workflow_dispatch` ゲートにしている。

対応プランに移行（または public 化）したら、本来の「main マージ → `production` 環境の承認ゲートで
待機 → 承認で apply」に戻せる。手順:

1. `production` 環境に required reviewers を設定（UI: Settings → Environments、または API）:

   ```bash
   gh api --method PUT repos/<org>/<repo>/environments/production --input - <<'JSON'
   { "wait_timer": 0, "prevent_self_review": false,
     "reviewers": [{ "type": "User", "id": <REVIEWER_USER_ID> }],
     "deployment_branch_policy": null }
   JSON
   # 単独運用で自分が承認者なら prevent_self_review=false。チームなら true 推奨。
   # reviewers は Team も可: { "type": "Team", "id": <TEAM_ID> }
   ```

2. `.github/workflows/cd-infra.yml` の `apply` を「main push で起動」に戻す:
   - `on:` に `push: { branches: [main], paths: ['infra/**', '.github/workflows/cd-infra.yml'] }`
     を復活（`workflow_dispatch` は残しても良い）。
   - `apply` ジョブの `if:` を
     `${{ github.event_name == 'push' && github.ref == 'refs/heads/main' }}` に戻す。
   - `apply` ジョブの `environment: production` は既にあるので、保護ルールが効けば
     **マージで apply がキューされ、承認されるまで待機**する（無承認の自動 provision は起きない）。

3. 動作確認: infra 変更を含む PR をマージ → cd-infra の `apply` が「Waiting / Review required」で
   停止 → 承認で初めて `terraform apply` が走ることを確認する。

> 注: 移行するまでは手動 `workflow_dispatch` がゲート。prod を立てる時は Actions →
> **CD Infra** → **Run workflow** で apply を起動する。

> **bootstrap 適用前の CI 挙動（重要）**
>
> `cd-infra.yml` の `plan`（PR）/ `apply`（手動 `workflow_dispatch`）は **OIDC でロールを
> 引き受けてから**動く。
> `infra/bootstrap/` を一度 apply し、出力したロール ARN を `AWS_PLAN_ROLE_ARN` /
> `AWS_DEPLOY_ROLE_ARN` に、state バケット名を `AWS_TF_STATE_BUCKET` に登録するまでは、
> **AWS 認証ステップ（`configure-aws-credentials`）で必ず失敗する**。これは想定挙動であり
> リグレッションではない。`AWS_TF_STATE_BUCKET` 未設定の場合は、認証を越えても直後の
> `terraform init`（backend.hcl のバケットが空）で失敗する。
>
> 一方 `ci.yml` の `infra` ジョブ（fmt / validate / tflint / checkov / trivy）は **AWS 認証
> 不要**なので、bootstrap 未適用でも green になる。PR で「`infra` は緑なのに `plan` が赤」と
> なっていたら、まず bootstrap とロール ARN 変数の登録状況を確認すること。

### `cd-app.yml`（インフラ作成後に有効化）

- **api**: `build`（ECR へ push, tag=SHA）→ **`migrate`（専用ジョブ）** → `deploy-api`（ECS 更新）。
  - `migrate` は、ビルドした image で **api タスク定義の新リビジョンを register** し、その
    リビジョンで **一回限りの Fargate タスク**（`aws ecs run-task`）を private subnet 内に起動して
    `uv run --no-sync alembic upgrade head` を実行、終了コード 0 を待ってから次へ進む（失敗時は
    サービスを更新しない）。`--no-sync` は private subnet に egress が無いため。
  - `deploy-api` は migrate が register した**新リビジョンへ `update-service`** して roll する。
    ECR は IMMUTABLE タグのため、`force-new-deployment` だけでは新イメージが反映されない。
- **web**: `npm run build` → `dist/` を S3 へ同期 → CloudFront を無効化。

参照する変数（リポジトリ Variables）: `AWS_DEPLOY_ROLE_ARN` / `ECR_REPOSITORY` /
`WEB_BUCKET` / `CLOUDFRONT_DISTRIBUTION_ID` / `ECS_CLUSTER` / `ECS_SERVICE` /
`ECS_TASK_FAMILY` / `PRIVATE_SUBNET_IDS` / `APP_SECURITY_GROUP_ID`。

### `metrics-dora.yml`（DORAメトリクス計測）

`cd-app.yml` の実行結果と merge 済み PR から、デプロイ頻度・変更リードタイムを週次で自動集計
（`schedule` + `workflow_dispatch`）し、job summary と [docs/metrics/](metrics/README.md) に
記録する。計測定義は [ADR-0006](adr/0006-dora-deployment-frequency-and-lead-time-definitions.md)
を参照（issue #237）。

### CI/CD のルール

- **長期 AWS キーを置かない。** 認証は GitHub OIDC → ジョブごとに IAM ロールを引き受ける
  （PR=plan ロール / main=deploy ロール）。`AWS_ACCESS_KEY_ID` を Secret に追加しない。
- **デプロイは CI で行い、手元で行わない。** `terraform apply` やイメージ push を手動で
  実行しない（`.claude/settings.json` が `terraform apply`/`destroy`/`aws`/`git push` を
  確認ゲートにしている）。
- 秘密は GitHub Environments / SSM / Secrets Manager から。コミットしない。

---

## ブートストラップ順序（新規 clone から）

1. `make setup` — ツールチェーンと git フック。
2. `infra/bootstrap/` をローカル state で一度だけ apply（state バケット・ロック表・OIDC・IAM ロール）。
3. アプリ層をリモート state に移行: `terraform init -backend-config=env/<env>.backend.hcl`
   （既存ローカル state があれば `-migrate-state`）。
4. 初回の `cd-infra.yml` でアプリ基盤をプロビジョニング → その後 `cd-app.yml` を有効化。

## 関連ドキュメント

- [app-development.md](app-development.md) — api / web のアプリ開発
- [metrics/README.md](metrics/README.md) — DORAメトリクス（デプロイ頻度・変更リードタイム）
- [`../CLAUDE.md`](../CLAUDE.md) — アーキテクチャと規約の正
