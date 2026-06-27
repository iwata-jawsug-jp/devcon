# devcon

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

アプリケーション開発とインフラ構築（IaC）のためのモノレポ。Dev Container 上で Terraform / AWS と
Python・Node/TypeScript の開発を行う。

## 構成

```
.
├── .devcontainer/      # Dev Container 定義（Terraform, AWS CLI, Python 3.14, Node 24, セキュリティツール）
├── infra/              # Terraform / AWS の IaC
│   ├── env/            # 環境ごとの tfvars（*.example のみコミット）
│   └── *.tf
├── services/
│   ├── api/            # Python アプリ（uv 管理）
│   └── web/            # Node / TypeScript アプリ
├── .pre-commit-config.yaml  # fmt / lint / セキュリティスキャンの自動実行
├── .tflint.hcl
└── Makefile            # よく使うコマンド集（`make help`）
```

## はじめに

Dev Container（VS Code: "Reopen in Container"）で開くと、以下が利用可能になる：
`terraform` / `tflint` / `trivy` / `checkov` / `aws` / `node` / `python3` / `uv` / `gh` / `docker`。

初期セットアップ：

```bash
make setup     # Python(uv) + Node(npm) 依存と pre-commit フックを導入
```

## ユーザー設定の永続化

Dev Container を rebuild しても各種ログイン・設定を再構築せずに済むよう、以下を
名前付き Docker ボリュームで永続化している（`.devcontainer/devcontainer.json` の `mounts`）。

| マウント先 | ボリューム | 内容 |
| --- | --- | --- |
| `~/.aws` | `devcon-aws` | AWS SSO プロファイル・トークン |
| `~/.config/gh` | `devcon-gh` | GitHub CLI の認証 |
| `~/.claude` | `devcon-claude` | Claude Code の設定・認証（`CLAUDE_CONFIG_DIR` で集約） |
| `~/.history` | `devcon-history` | bash コマンド履歴 |

- Claude Code は `CLAUDE_CONFIG_DIR=/home/vscode/.claude` を設定し、設定・認証
  （`.credentials.json`）をこのボリューム配下にまとめている。
- 名前付きボリュームは root 所有で作られるため、`.devcontainer/init-persist.sh` が
  rebuild ごとに `vscode` へ chown し直す（`postCreateCommand` から冪等に実行）。
- **初回のみ** ボリュームが空のため各サービスへ一度ログインが必要。以降は rebuild を
  またいで残る。ボリュームを消すと設定もリセットされる（`docker volume rm devcon-*`）。

## Git 初期設定

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

## Claude Code 初期設定

[Claude Code](https://docs.claude.com/claude-code) CLI と VS Code 拡張は Dev Container に
プリインストール済み（`@anthropic-ai/claude-code` / 拡張 `anthropic.claude-code`）。

```bash
claude --version   # 動作確認
claude             # 初回起動時にブラウザでログイン（認証は端末ごとに一度）
```

このリポジトリの Claude 用設定：

| ファイル | 用途 | Git |
| --- | --- | --- |
| `CLAUDE.md` | リポジトリ構成・コマンド・規約を Claude に伝えるガイド | コミットする |
| `.claude/settings.json` | チーム共有の権限設定（許可/確認/拒否コマンド） | コミットする |
| `.claude/settings.local.json` | 個人用の上書き設定 | コミットしない（`.gitignore` 済み） |

`.claude/settings.json` では安全なコマンド（`make` / `terraform fmt` / `uv run` など）を
自動許可、`terraform apply`・`destroy`・`aws`・`git push` は実行前に確認、
秘密情報（`*.tfvars` / `.env` / 鍵）の読み取りは拒否する設定にしてある。
個人的に許可コマンドを増やしたい場合は `.claude/settings.local.json` に書く。

## AWS SSO 初期設定

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

## よく使うコマンド

```bash
make help        # 全コマンド一覧
make fmt         # 全体フォーマット（terraform fmt / ruff / prettier）
make lint        # 全体 Lint（tflint / ruff+mypy / eslint+tsc）
make test        # 全テスト（pytest / node --test）
make security    # Trivy + Checkov で infra をスキャン
```

### インフラ（Terraform）

```bash
make tf-init
make tf-plan     # infra/env/dev.tfvars があれば使用
```

リモート state（S3 + DynamoDB ロック）は `infra/backend.tf` のコメントを参照。

### Python（services/api）

```bash
cd services/api
uv sync
uv run pytest
```

### Node / TypeScript（services/web）

```bash
cd services/web
npm install
npm run dev      # src/index.ts を直接実行
npm test
```

## 品質ゲート

`pre-commit install`（`make hooks`）後、コミット時に自動で以下が走る：

- 汎用: 末尾空白・改行・大容量ファイル・秘密鍵検出
- Terraform: `fmt` / `validate` / `tflint` / `checkov` / `trivy`
- Python: `ruff`（lint + format）
- Node 系: `prettier`

## セキュリティ

- 秘密情報（`.env`, `*.tfvars`, 認証情報, 鍵）はコミットしない（`.gitignore` 済み）。
- `*.example` ファイルをテンプレートとして用意。

## ライセンス

[MIT License](LICENSE) のもとで公開している。

> このリポジトリのコード・ドキュメントの一部は [Claude Code](https://www.anthropic.com/claude-code)
> （AI）の支援を受けて作成している。生成物の権利は作成者に帰属し、MIT License のもとで提供する。
