# devcon

[![CI](https://github.com/iwata-jawsug-jp/devcon/actions/workflows/ci.yml/badge.svg)](https://github.com/iwata-jawsug-jp/devcon/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/tag/iwata-jawsug-jp/devcon?sort=semver&label=release)](https://github.com/iwata-jawsug-jp/devcon/tags)
[![Security Policy](https://img.shields.io/badge/Security-Policy-blue.svg)](SECURITY.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Web アプリケーションとそのインフラ（IaC）のためのモノレポ。Dev Container 上で、
**FastAPI** バックエンド・**Vite + Vue 3** フロントエンド・**Terraform / AWS** を開発する。
設計・規約の詳細は [`CLAUDE.md`](CLAUDE.md) を参照。

このプロジェクトを自分で使うには、公開リポジトリ（`iwata-jawsug-jp/devcon`）を **fork** するか、
[`copier`](#自分の名前でプロジェクトを生成するスキャフォールド) でプロジェクト名・GitHub org/repo・
AWS リージョンを指定した「命名済み」の新規プロジェクトとして生成する。アプリをローカルで動かす
だけなら AWS は不要（下記「クイックスタート（ローカル）」）。CI/CD で自分の AWS にデプロイするには
「本格セットアップ（自分の AWS で実開発）」を行う。

## 概要

### 構成

```
.
├── .devcontainer/      # Dev Container 定義（Terraform, AWS CLI, Python 3.14, Node 24, セキュリティツール）
├── .github/workflows/  # CI/CD（ci.yml / cd-infra.yml / cd-app.yml）
├── infra/              # Terraform / AWS の IaC
│   ├── bootstrap/      # 初回のみ・ローカル state（state バケット, OIDC, CI IAM ロール）
│   ├── env/            # 環境ごとの tfvars / backend hcl（*.example のみコミット）
│   └── *.tf            # アプリ基盤（web=S3+CloudFront, api=ECR+ECS, shared=VPC ほか）
├── services/
│   ├── backend/
│   │   └── python/     # バックエンド REST API（Python / FastAPI / uv 管理）
│   └── frontend/       # フロントエンド SPA（TypeScript / Vite + Vue 3）
├── .pre-commit-config.yaml  # fmt / lint / セキュリティスキャンの自動実行
├── .tflint.hcl
└── Makefile            # よく使うコマンド集（`make help`）
```

### アーキテクチャ

- `frontend`（静的 SPA）と `backend`（ステートレス JSON API）は別プロセス。ブラウザは相対パス
  `/api/*` で API を呼ぶ。
- 開発時は Vite(:5173) が `/api/*` を uvicorn(:8000) にプロキシ（ローカルでは CORS 不要）。
  本番は CloudFront が `/api/*` を api オリジンへルーティング。
- API 契約は FastAPI の OpenAPI（`/openapi.json`）。TS の型は `make gen-types` で生成し、
  リクエスト/レスポンス型を二重管理しない。

## クイックスタート（ローカル）

**AWS は不要。** Dev Container でアプリをローカル起動するだけなら、この節で完結する。

Dev Container（VS Code: "Reopen in Container"）で開くと、以下が利用可能になる：
`terraform` / `tflint` / `trivy` / `checkov` / `aws` / `node` / `python3` / `uv` / `gh` / `docker`。

```bash
make setup     # Python(uv) + Node(npm) 依存と pre-commit フックを導入
make dev       # backend(:8000) と frontend(:5173) を同時起動
# アプリ: http://localhost:5173 ・ API ドキュメント: http://localhost:8000/docs
```

コミットする場合は、続けて「本格セットアップ」の [Git 初期設定](#git-初期設定) を済ませる。

## 自分の名前でプロジェクトを生成する（スキャフォールド）

単に fork するのではなく、プロジェクト名・GitHub org/repo・AWS リージョンを指定して
「命名済み・置換済み」の新規プロジェクトとして生成することもできる
（[`copier`](https://copier.readthedocs.io/) を採用した経緯は
[ADR-0010](docs/adr/0010-adopt-copier-for-scaffold-cli.md)、本リポジトリ自身をテンプレートに
した理由は [ADR-0011](docs/adr/0011-scaffold-template-in-place.md) を参照）。

前提: `copier`（`uv tool install copier` または `pip install copier`。バージョンは
`.devcontainer/Dockerfile` の `COPIER_VERSION` を参照。Dev Container には導入済み）。

```bash
copier copy gh:iwata-jawsug-jp/devcon <生成先ディレクトリ>
```

対話式で次の変数を聞かれる：

| 変数           | 説明                                                                                                                      | 例               |
| -------------- | ------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| `project_name` | プロジェクト名。S3 バケット名・ECR リポジトリ名・Cognito ドメインの一部に使うため、小文字英数字とハイフンのみ、3〜63 文字 | `my-project`     |
| `github_org`   | GitHub organization または user 名（`infra/bootstrap` の OIDC 信頼ポリシーに使う）                                        | `your-org`       |
| `github_repo`  | GitHub リポジトリ名（省略時は `project_name` と同じ）                                                                     | `my-project`     |
| `aws_region`   | デプロイ先の AWS リージョン                                                                                               | `ap-northeast-1` |

生成先には `devcon` / `itouhi` / `ap-northeast-1` の文字列がすべて置換されたプロジェクトが
できる（コピー後に sed で置換する方式。チェックイン済みファイルは一切変更しない。詳細は
[`docs/scaffold-cli.md`](docs/scaffold-cli.md)）。

**生成後にやること:**

1. `CODE_OF_CONDUCT.md` の違反報告先メールアドレスを確認する。機械的に置換されるが実在する
   アドレスとは限らないため、必ず自分（またはプロジェクトの連絡先）のアドレスに書き換える。
2. 新しい GitHub リポジトリを作成し、生成物を push する。
3. 次の「本格セットアップ（自分の AWS で実開発）」（Git 初期設定 → AWS SSO 設定 →
   `infra/bootstrap` の初回 apply → リポジトリ変数登録）を行う。fork の場合と同じ手順で、
   生成方法によって変わらない。

生成物が CI で green になることは `make scaffold-verify`（`ci.yml` の `scaffold` ジョブ）で
継続的に検証している。

### 生成後にテンプレートの更新を取り込む（`copier update`）

`copier copy` で生成したプロジェクトは、`git init` してコミットしておけば
[`copier update`](https://copier.readthedocs.io/en/stable/updating/) で本テンプレート
（`devcon`）側の更新を後から取り込める（#298 で実機検証済み。詳細は
[`docs/scaffold-cli.md`](docs/scaffold-cli.md#copier-update下流追従298で判明した設計ギャップと対応)
参照）。

```bash
cd <生成先ディレクトリ>
copier update --trust
```

- 本テンプレートはリリースの度に `vX.Y.Z` タグを打つ運用（`docs/release.md`）
  のため、`--vcs-ref` を省略すると**最新リリースタグ**に更新される（最新コミットではない）。
  最新の未リリース変更まで取り込みたい場合は `copier update --trust --vcs-ref=HEAD`（自分の
  `devcon` クローンを `_src_path` に指定して生成した場合のみ有効）。
- 生成先で独自にカスタマイズした行が、同じ行でテンプレート側も変更されていた場合は
  `<<<<<<< before updating` / `=======` / `>>>>>>> after updating` という git 風の
  コンフリクトマーカーがファイル内に挿入される。通常の git マージ衝突と同じ要領で解決し、
  コミットする。
- 破壊的変更（`copier.yml` の変数追加・削除・改名、生成ファイル構成の変更等）は
  [`CHANGELOG.md`](CHANGELOG.md) の該当リリースエントリに明記する運用にしている。
  `copier update` の前に更新元リポジトリの CHANGELOG を確認することを推奨する。

## 本格セットアップ（自分の AWS で実開発）

ローカルで動かすだけなら上記で十分。**コミットして開発を進め、CI/CD で自分の AWS へ
デプロイする**には、以下を行う。手順の実体・全変数は [`docs/infrastructure.md`](docs/infrastructure.md)
を正とし、ここは要約に留める。

### Git 初期設定

リポジトリを clone した後、コミット前に identity を設定する。`user.email` は
メールアドレスを公開しないよう **GitHub の noreply メール**（`<ID>+<user>@users.noreply.github.com`）
を推奨。ID は `https://api.github.com/users/<ユーザー名>` の `id` で確認できる。

```bash
# このリポジトリ限定の identity（--global を付ければ全リポジトリ共通）
git config --local user.name  "あなたの名前"
git config --local user.email "<ID>+<ユーザー名>@users.noreply.github.com"

# 推奨デフォルト
git config --local pull.rebase true            # pull 時に履歴を直線化
git config --local push.autoSetupRemote true   # 初回 push で upstream を自動設定
git config --local fetch.prune true            # 削除済みリモートブランチを整理
```

リモートと認証：

```bash
git remote -v                      # origin が設定済みか確認
ssh -T git@github.com              # SSH 認証の確認（"Hi <user>!" が出れば OK）
git push -u origin main           # 初回 push（upstream を設定）
```

> プライベートメールで push が `GH007` で拒否される場合は、上記の noreply メールに
> 切り替えて `git commit --amend --reset-author --no-edit` で author を書き換える。
> `gh` で PR 操作をする場合は `gh auth login` を実行。

### AWS SSO 初期設定

`tools/script/aws-sso-setup.sh` で AWS SSO プロファイルの作成・ログイン・認証確認を
一括で行う。`sso_account_id` と SSO start URL は環境固有のため**必須**（既定値を持たない）。

```bash
./tools/script/aws-sso-setup.sh -a <sso_account_id> -u <start_url>
# 例: -a 123456789012 -u https://<your-portal>.awsapps.com/start
```

実行すると次の 3 ステップが走る：

1. `~/.aws/config` に `[default]` プロファイルを書き込む（`aws configure set` を使うため既存の他プロファイルは保持）
2. `aws sso login` でブラウザ認証
3. `aws sts get-caller-identity` で認証できたか確認

`~/.aws` は Docker ボリュームで永続化しているため、一度ログインすれば devcontainer を
rebuild してもプロファイルと SSO トークンは残る（期限切れ時のみ `aws sso login` を再実行）。

リージョン / ロール名などは既定値（`ap-northeast-1` / `AWSAdministratorAccess`）を持つ。
変更する場合はオプションで上書き：

```bash
./tools/script/aws-sso-setup.sh --help                              # 全オプション
./tools/script/aws-sso-setup.sh -a <id> -u <start_url> -p dev -n PowerUserAccess
```

> IAM Identity Center が使えない（個人アカウント等で未導入の）場合は、代替の一時クレデンシャル
> 発行手順を [`docs/aws-temporary-credentials.md`](docs/aws-temporary-credentials.md) にまとめて
> ある（IAM ユーザー + `get-session-token` / `assume-role`、IAM Roles Anywhere、CloudShell 経由）。

### 自分の AWS にデプロイする

CI/CD（GitHub OIDC → IAM ロール）で自分の AWS へデプロイできるよう、**一度だけ**土台を作る。

1. 上記の **AWS SSO 設定**でアカウントにログインする。
2. **`infra/bootstrap/` を一度だけ apply** して、OIDC プロバイダ・CI IAM ロール・state バケットを
   作る：`tools/script/bootstrap.sh init -p <project>`（`github_org`/`github_repo` は自分の fork を
   自動検出。OIDC trust がこのリポジトリに限定されるため、**既定値のままだと fork 先の CD が
   認証で失敗する**点は変わらない）。
3. `tools/script/bootstrap.sh write` で bootstrap の出力を**リポジトリ変数**に登録する：`AWS_TF_STATE_BUCKET` /
   `AWS_PLAN_ROLE_ARN` / `AWS_DEPLOY_ROLE_ARN` / `PROJECT_NAME`。**未登録だと `cd-infra.yml` の
   plan/apply は OIDC 認証段階、または `PROJECT_NAME` 不一致による state ロック取得の
   `AccessDenied` で失敗する**（想定挙動）。
4. `cd-infra.yml`（PR で `terraform plan`、手動実行で `apply`）でアプリ基盤を作成し、続けて
   `cd-app.yml` 用の変数（`ECR_REPOSITORY` ほか）を登録してアプリをデプロイする。

> 各ステップの具体コマンドと全変数は [`docs/infrastructure.md`](docs/infrastructure.md) の
> 「ブートストラップ順序（新規 clone から）」を参照。

## リファレンス

### よく使うコマンド

```bash
make help        # 全コマンド一覧
make dev         # backend(:8000) + frontend(:5173) を同時起動
make gen-types   # API の OpenAPI から frontend の TS 型を生成
make fmt         # 全体フォーマット（terraform fmt / ruff / prettier）
make lint        # 全体 Lint（tflint / ruff+mypy / eslint+vue-tsc）
make test        # 全テスト（pytest / vitest）
make security    # Trivy + Checkov で infra をスキャン
```

#### インフラ（Terraform）

```bash
make tf-init                              # ローカル init
make tf-init BACKEND=env/dev.backend.hcl  # リモート state で init
make tf-plan                              # infra/env/dev.tfvars があれば使用
```

2 層構成。詳細は [`CLAUDE.md`](CLAUDE.md) の Infrastructure / Bootstrap order を参照。

- `infra/bootstrap/` … 初回のみローカル state で適用（state バケット・OIDC・CI IAM ロール）。
- アプリ基盤 … リモート state（`terraform init -backend-config=env/<env>.backend.hcl`）で
  `cd-infra.yml` が管理。

#### バックエンド API（services/backend/python · FastAPI）

```bash
cd services/backend/python
uv sync
uv run uvicorn api.main:app --reload   # http://localhost:8000/docs
uv run pytest
```

#### フロントエンド SPA（services/frontend · Vite + Vue 3）

```bash
cd services/frontend
npm install
npm run dev        # Vite dev server（/api は :8000 にプロキシ）
npm test           # Vitest（ユニット）
npm run test:e2e   # Playwright（E2E）
```

### CI/CD

`.github/workflows/` の GitHub Actions が Makefile / pre-commit と同じゲートを実行する
（"ローカルで green" == "CI で green"）。AWS 認証は **長期キーを使わず GitHub OIDC** で
IAM ロールを引き受ける。詳細は [`CLAUDE.md`](CLAUDE.md) の CI/CD を参照。

- `ci.yml` … PR / main push で変更パスのみ per-service ジョブ（backend / frontend / infra）。
- `cd-infra.yml` … PR で `terraform plan`、手動実行（`workflow_dispatch`）で `apply`。
- `cd-app.yml` … backend イメージを ECR へ push し ECS を更新、frontend を S3 同期 + CloudFront 無効化。

### 品質ゲート

`pre-commit install`（`make hooks`）後、コミット時に自動で以下が走る：

- 汎用: 末尾空白・改行・大容量ファイル・秘密鍵検出
- Terraform: `fmt` / `validate` / `tflint` / `checkov` / `trivy`
- Python: `ruff`（lint + format）
- Node 系: `prettier`

### ユーザー設定の永続化

Dev Container を rebuild しても各種ログイン・設定を再構築せずに済むよう、以下を
名前付き Docker ボリュームで永続化している（`.devcontainer/devcontainer.json` の `mounts`）。

| マウント先     | ボリューム              | 内容                                                   |
| -------------- | ----------------------- | ------------------------------------------------------ |
| `~/.aws`       | `devcon-aws`     | AWS SSO プロファイル・トークン                         |
| `~/.config/gh` | `devcon-gh`      | GitHub CLI の認証                                      |
| `~/.claude`    | `devcon-claude`  | Claude Code の設定・認証（`CLAUDE_CONFIG_DIR` で集約） |
| `~/.history`   | `devcon-history` | bash コマンド履歴                                      |

- Claude Code は `CLAUDE_CONFIG_DIR=/home/vscode/.claude` を設定し、設定・認証
  （`.credentials.json`）をこのボリューム配下にまとめている。
- 名前付きボリュームは root 所有で作られるため、`.devcontainer/init-persist.sh` が
  rebuild ごとに `vscode` へ chown し直す（`postCreateCommand` から冪等に実行）。
- **初回のみ** ボリュームが空のため各サービスへ一度ログインが必要。以降は rebuild を
  またいで残る。ボリュームを消すと設定もリセットされる（`docker volume rm devcon-*`）。

### Claude Code 設定

[Claude Code](https://docs.claude.com/claude-code) CLI と VS Code 拡張は Dev Container に
プリインストール済み（`@anthropic-ai/claude-code` / 拡張 `anthropic.claude-code`）。

```bash
claude --version   # 動作確認
claude             # 初回起動時にブラウザでログイン（認証は端末ごとに一度）
```

このリポジトリの Claude 用設定：

| ファイル                      | 用途                                                   | Git                                 |
| ----------------------------- | ------------------------------------------------------ | ----------------------------------- |
| `CLAUDE.md`                   | リポジトリ構成・コマンド・規約を Claude に伝えるガイド | コミットする                        |
| `.claude/settings.json`       | チーム共有の権限設定（許可/確認/拒否コマンド）         | コミットする                        |
| `.claude/settings.local.json` | 個人用の上書き設定                                     | コミットしない（`.gitignore` 済み） |

`.claude/settings.json` では安全なコマンド（`make` / `terraform fmt` / `uv run` など）を
自動許可、`terraform apply`・`destroy`・`aws`・`git push` は実行前に確認、
秘密情報（`*.tfvars` / `.env` / 鍵）の読み取りは拒否する設定にしてある。
個人的に許可コマンドを増やしたい場合は `.claude/settings.local.json` に書く。

### セキュリティ

- 秘密情報（`.env`, `*.tfvars`, 認証情報, 鍵）はコミットしない（`.gitignore` 済み）。
- `*.example` ファイルをテンプレートとして用意。

## ライセンス

[MIT License](LICENSE) のもとで公開している。

> このリポジトリのコード・ドキュメントの一部は [Claude Code](https://www.anthropic.com/claude-code)
> （AI）の支援を受けて作成している。生成物の権利は作成者に帰属し、MIT License のもとで提供する。
