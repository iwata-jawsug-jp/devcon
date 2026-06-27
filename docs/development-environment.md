# 開発環境ガイド

このリポジトリは **Dev Container** 上で開発する。コンテナを開けば Terraform / AWS CLI /
Python / Node / セキュリティツールがすべて揃った状態になり、ホスト側に個別インストールは不要。

- 概要・各設定の詳細はリポジトリ直下の [`README.md`](../README.md) を参照。
- このドキュメントは「日々どう使うか」をワークフロー順にまとめたもの。

---

## 1. 前提

ホスト側に必要なのは次の 3 つだけ。

- [Docker](https://www.docker.com/)（Docker Desktop など）
- [VS Code](https://code.visualstudio.com/)
- VS Code 拡張 [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)

コンテナ内に入るツール（ホストへのインストール不要）:

| 種別 | ツール | バージョン |
| --- | --- | --- |
| ベース | Ubuntu | 22.04 |
| 言語 | Python | 3.14 |
| 言語 | Node.js | 24 |
| Python 管理 | uv | latest |
| IaC | Terraform / tflint | latest |
| セキュリティ | trivy / checkov | latest |
| クラウド | AWS CLI v2 | latest |
| その他 | gh / docker(dind) / ripgrep / Claude Code | latest |

---

## 2. コンテナの起動

1. リポジトリを clone する。
2. VS Code でフォルダを開く。
3. コマンドパレット → **Dev Containers: Reopen in Container**（初回はイメージビルドのため数分）。
4. ビルド完了後、`postCreateCommand` が各ツールのバージョンを表示する。エラーなく一覧が出れば成功。

> rebuild したいとき: コマンドパレット → **Dev Containers: Rebuild Container**。
> ユーザー設定（後述）はボリュームに残るため、再ログインは基本不要。

---

## 3. 初回セットアップ

コンテナに入ったら一度だけ実行する。

```bash
make setup     # Python(uv) + Node(npm) 依存と pre-commit フックを一括導入
```

`make setup` の内訳:

- `api-setup` … `services/api` で `uv sync`
- `web-setup` … `services/web` で `npm install`
- `hooks` … `pre-commit install`（コミット時に fmt/lint/security を自動実行）

各サービスへの初回ログイン（ボリュームに永続化されるため一度きり）:

```bash
gh auth login                                       # GitHub CLI
claude                                               # Claude Code（ブラウザ認証）
./tools/script/aws-sso-setup.sh -a <id> -u <start_url>  # AWS SSO（account-id と start URL は必須）
```

---

## 4. 日々のワークフロー

`make help` で全コマンドを確認できる。代表的なものは以下。

### 全体

```bash
make fmt         # 整形（terraform fmt / ruff format / prettier）
make lint        # 静的解析（tflint / ruff+mypy / eslint+tsc）
make test        # テスト（pytest / node --test）
make security    # Trivy + Checkov で infra をスキャン
```

### インフラ（Terraform / `infra/`）

```bash
make tf-init
make tf-validate
make tf-plan     # infra/env/dev.tfvars があれば自動で -var-file 指定
make tf-lint
```

- リージョン既定値は `ap-northeast-1`。
- リモート state（S3 + ネイティブロック `use_lockfile`）は `infra/backend.tf` のコメント参照。
- 環境別変数は `infra/env/*.tfvars`。コミットするのは `*.example` のみ。

### Python（`services/api/`）

uv 管理。`python`/`pip` を直接使わず必ず `uv run` 経由で実行する。

```bash
cd services/api
uv sync                 # 依存同期
uv run pytest           # テスト
uv run ruff check .     # lint
uv run ruff format .    # format
uv run mypy             # 型チェック（strict）
```

規約: ruff（line length 100 / `py312` target）、mypy strict、型ヒント必須。

### Node / TypeScript（`services/web/`）

```bash
cd services/web
npm install
npm run dev      # src/index.ts を直接実行
npm test         # node --test
npm run lint     # eslint
npm run typecheck
npm run build    # tsc
```

規約: strict mode、ESM（`type: module`）、eslint + prettier。

---

## 5. コミット前の品質ゲート

`make hooks`（= `pre-commit install`）後、`git commit` で自動実行される。

- 汎用: 末尾空白・改行・大容量ファイル・秘密鍵検出
- Terraform: `fmt` / `validate` / `tflint` / `checkov` / `trivy`
- Python: `ruff`（lint + format）
- Node 系: `prettier`

> `--no-verify` でのバイパスは禁止（CLAUDE.md の規約）。失敗したら原因を直す。

---

## 6. ユーザー設定の永続化

rebuild してもログイン・履歴を保持できるよう、名前付き Docker ボリュームで永続化している
（`.devcontainer/devcontainer.json` の `mounts`）。

| マウント先 | ボリューム | 内容 |
| --- | --- | --- |
| `~/.aws` | `devcon-aws` | AWS SSO プロファイル・トークン |
| `~/.config/gh` | `devcon-gh` | GitHub CLI の認証 |
| `~/.claude` | `devcon-claude` | Claude Code の設定・認証（`CLAUDE_CONFIG_DIR`） |
| `~/.history` | `devcon-history` | bash コマンド履歴 |

- 名前付きボリュームは root 所有で作られるため、`.devcontainer/init-persist.sh` が
  rebuild ごとに `vscode` へ chown し直す（`postCreateCommand` から冪等に実行）。
- **初回のみ** 各サービスへログインが必要。以降は rebuild をまたいで残る。
- リセットしたい場合はボリュームを削除: `docker volume rm devcon-aws devcon-gh devcon-claude devcon-history`。

---

## 7. トラブルシューティング

| 症状 | 対処 |
| --- | --- |
| ツールのバージョンが出ない / コマンドが無い | **Rebuild Container** を実行。直らなければイメージをクリーンビルド。 |
| AWS が `ExpiredToken` 等で失敗 | `aws sso login` を再実行（トークン期限切れ）。 |
| push が `GH007` で拒否される | identity を GitHub noreply メールに切り替え、`git commit --amend --reset-author --no-edit`。詳細は README「Git 初期設定」。 |
| `~/.aws` などが root 所有でアクセスできない | `bash .devcontainer/init-persist.sh` を手動実行（冪等）。 |
| bash 履歴が残らない | `~/.history` ボリュームと `.bashrc` の履歴設定を確認。新規ターミナルから有効。 |
| pre-commit が走らない | `make hooks`（= `pre-commit install`）を再実行。 |

---

## 関連ドキュメント

- [`README.md`](../README.md) — 構成・各種初期設定（Git / Claude Code / AWS SSO）の詳細
- [`CLAUDE.md`](../CLAUDE.md) — Claude Code 向けのリポジトリガイドと規約
