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
  - `*-ci-plan` … PR 用の読み取り専用（plan）
  - `*-ci-deploy` … main / `production` 用のデプロイ
  - いずれも assume-role を OIDC の `sub`/`aud` 条件（org/repo）で制限

```bash
cd infra/bootstrap
terraform init                 # ローカル state（backend ブロックなし）
terraform apply                # 一度だけ
terraform output               # state バケット名 / ロック表 / ロール ARN を控える
```

出力した値を後段（アプリ層の backend hcl、CI のロール ARN 変数）に設定する。

### 2. アプリ層（`infra/*.tf`・リモート state）

`cd-infra.yml` が管理。`backend.tf` は **部分設定**（`backend "s3" {}`）で、env ごとの
hcl を渡して初期化する。

| ファイル | 内容（現状はスキャフォールド + `# TODO`） |
| --- | --- |
| `web.tf` | SPA 配信用のプライベート S3。TODO: CloudFront(OAC) / ACM・Route53 |
| `api.tf` | ECR リポジトリ。TODO: ECS Fargate + ALB（代替: Lambda + API GW） |
| `shared.tf` | CloudWatch ロググループ。TODO: VPC / タスク IAM |
| `providers.tf` / `versions.tf` / `variables.tf` / `outputs.tf` / `backend.tf` | 共通定義 |

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

| ワークフロー | トリガー | 役割 |
| --- | --- | --- |
| `ci.yml` | PR / main push | 変更パスのみ per-service で検証 |
| `cd-infra.yml` | PR / main push | Terraform plan（PR）/ apply（main） |
| `cd-app.yml` | main push / 手動 | アプリのビルド & デプロイ |
| `publish.yml` | Release 公開 | 公開リポジトリへのミラー（[release.md](release.md)） |

### `ci.yml`

パスフィルタで、変更のあったサービスのジョブだけ実行する。

- **api**: `uv sync` → ruff → mypy → pytest
- **web**: `npm ci` → eslint → `vue-tsc --noEmit` → vitest → build（→ Playwright e2e）
- **infra**: `terraform fmt -check` → `init -backend=false` → validate → tflint → checkov + trivy

### `cd-infra.yml`

- **PR**: `terraform plan` を実行し、結果を PR にコメント（plan ロール）。
- **main マージ**: `terraform apply`。保護された GitHub Environment `production` で承認ゲート
  （deploy ロール）。

### `cd-app.yml`（インフラ作成後に有効化）

- **api**: イメージをビルドして ECR へ push → ECS サービスを更新（force new deployment）。
- **web**: `npm run build` → `dist/` を S3 へ同期 → CloudFront を無効化。

参照する変数（リポジトリ Variables）: `AWS_DEPLOY_ROLE_ARN` / `ECR_REPOSITORY` /
`WEB_BUCKET` / `CLOUDFRONT_DISTRIBUTION_ID` / `ECS_CLUSTER` / `ECS_SERVICE`。

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
- [release.md](release.md) — 公開リポジトリへのリリースフロー
- [`../CLAUDE.md`](../CLAUDE.md) — アーキテクチャと規約の正
