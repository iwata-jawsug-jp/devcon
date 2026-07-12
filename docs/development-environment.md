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

| 種別         | ツール                                    | バージョン       |
| ------------ | ----------------------------------------- | ---------------- |
| ベース       | Ubuntu                                    | 22.04            |
| 言語         | Python                                    | 3.14             |
| 言語         | Node.js                                   | 24（major 固定） |
| Python 管理  | uv                                        | 0.11.24          |
| IaC          | Terraform / tflint                        | 1.13.0 / 0.63.1  |
| セキュリティ | trivy / checkov                           | 0.71.2 / 3.3.2   |
| クラウド     | AWS CLI v2                                | latest           |
| その他       | gh / docker(dind) / ripgrep / Claude Code | latest           |

バージョン固定の単一ソースは `.devcontainer/Dockerfile` 先頭の `ARG` 群（更新手順は
[§8](#8-ツールバージョンの更新手順)）。Terraform は CI（`ci.yml` / `cd-infra.yml`）の pin と
常に同一に保つ。

---

## 2. コンテナの起動

1. リポジトリを clone する。
2. VS Code でフォルダを開く。
3. コマンドパレット → **Dev Containers: Reopen in Container**（初回はイメージビルドのため数分）。
4. ビルド完了後、`postCreateCommand`（`.devcontainer/post-create.sh`）が各ツールの
   バージョン表示と `make setup` を実行する。エラーなく一覧が出れば成功。

> rebuild したいとき: コマンドパレット → **Dev Containers: Rebuild Container**。
> ユーザー設定（後述）はボリュームに残るため、再ログインは基本不要。

---

## 3. 初回セットアップ

`make setup`（Python(uv) + Node(npm) 依存と pre-commit フックの一括導入）はコンテナ作成時に
`postCreateCommand`（`.devcontainer/post-create.sh`）が自動実行するため、手動実行は不要。
ネットワーク断などで失敗した場合は `WARN: make setup failed` が出るので、`make setup` を
手動で再実行する（冪等なので何度実行してもよい）。

`make setup` の内訳:

- `backend-setup` … `services/backend/python` で `uv sync`
- `frontend-setup` … `services/frontend` で `npm install`
- `hooks` … `pre-commit install`（コミット時に fmt/lint/security を自動実行）

手動で残るのは各サービスへの初回ログインのみ（ボリュームに永続化されるため一度きり）:

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
make dev         # Postgres 起動 → backend(:8000) と frontend(:5173) を同時起動
make fmt         # 整形（terraform fmt / ruff format / prettier）
make lint        # 静的解析（tflint / ruff+mypy / eslint+vue-tsc）
make test        # テスト（pytest / vitest）
make security    # Trivy + Checkov で infra をスキャン
make gen-types   # API の OpenAPI スキーマからフロントの TS 型を生成
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

### Python（`services/backend/python/`）

uv 管理。`python`/`pip` を直接使わず必ず `uv run` 経由で実行する。

```bash
cd services/backend/python
uv sync                 # 依存同期
uv run pytest           # テスト
uv run ruff check .     # lint
uv run ruff format .    # format
uv run mypy             # 型チェック（strict）
```

規約: ruff（line length 100 / `py314` target）、mypy strict、型ヒント必須。

### Node / TypeScript（`services/frontend/`、Vite + Vue 3）

```bash
cd services/frontend
npm install
npm run dev       # Vite dev サーバー（:5173、/api は uvicorn :8000 へプロキシ）
npm test          # vitest（--coverage 付き）
npm run test:e2e  # Playwright E2E
npm run lint      # eslint
npm run typecheck # vue-tsc --noEmit
npm run build     # vue-tsc + vite-ssg build（全ルートをプリレンダー）
```

規約: Vue 3 Composition API（`<script setup lang="ts">`）、strict mode、ESM（`type: module`）、
eslint + prettier。型チェックは必ず `vue-tsc`（`tsc` は Vue の型を解決できないため不可）。

> `make ci-frontend`（CI のフロントエンドジョブのローカル再現）に含まれる Lighthouse CI は
> Chrome を必要とするが、Dev Container には Chrome を同梱していない。そのため Makefile は
> `CHROME_PATH` 未設定かつ Chrome 系コマンドが見つからない場合に限り、Playwright の
> chromium（`npx playwright install chromium` で導入済みのもの）へ自動フォールバックする。
> CI の Ubuntu ランナーは Chrome 同梱のためフォールバックは発動しない。

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

| マウント先        | ボリューム              | 内容                                                                                |
| ----------------- | ----------------------- | ----------------------------------------------------------------------------------- |
| `~/.aws`          | `devcon-aws`     | AWS SSO プロファイル・トークン                                                      |
| `~/.config/gh`    | `devcon-gh`      | GitHub CLI の認証                                                                   |
| `~/.claude`       | `devcon-claude`  | Claude Code の設定・認証（`CLAUDE_CONFIG_DIR`）                                     |
| `~/.history`      | `devcon-history` | bash コマンド履歴                                                                   |
| `/var/lib/docker` | `devcon-dind`    | Docker-in-Docker のレイヤーキャッシュ（rebuild のたびにイメージを取り直さないため） |

- 名前付きボリュームは root 所有で作られるため、`.devcontainer/init-persist.sh` が
  rebuild ごとに `vscode` へ chown し直す（`postCreateCommand` から冪等に実行）。
- **初回のみ** 各サービスへログインが必要。以降は rebuild をまたいで残る。
- Docker を docker-in-docker（`--privileged`）方式にしている理由は
  [ADR-0005](adr/0005-adopt-docker-in-docker-with-privileged-for-devcontainer.md) を参照。
- リセットしたい場合はボリュームを削除: `docker volume rm devcon-aws devcon-gh devcon-claude devcon-history devcon-dind`。

---

## 7. トラブルシューティング

| 症状                                        | 対処                                                                                                                        |
| ------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| ツールのバージョンが出ない / コマンドが無い | **Rebuild Container** を実行。直らなければイメージをクリーンビルド。                                                        |
| AWS が `ExpiredToken` 等で失敗              | `aws sso login` を再実行（トークン期限切れ）。                                                                              |
| push が `GH007` で拒否される                | identity を GitHub noreply メールに切り替え、`git commit --amend --reset-author --no-edit`。詳細は README「Git 初期設定」。 |
| `~/.aws` などが root 所有でアクセスできない | `bash .devcontainer/init-persist.sh` を手動実行（冪等）。                                                                   |
| bash 履歴が残らない                         | `~/.history` ボリュームと `.bashrc` の履歴設定を確認。新規ターミナルから有効。                                              |
| pre-commit が走らない                       | `make hooks`（= `pre-commit install`）を再実行。                                                                            |

---

## 8. ツールバージョンの更新手順

Terraform / tflint / trivy / checkov / uv のバージョンは `.devcontainer/Dockerfile` 先頭の
`ARG` に集約している（#109）。上げるときは次の手順で。

1. `.devcontainer/Dockerfile` の対象 `ARG`（`TERRAFORM_VERSION` / `TFLINT_VERSION` /
   `TRIVY_VERSION` / `CHECKOV_VERSION` / `UV_VERSION`）を書き換える。
2. **Terraform だけは CI と同時に更新する。** `ci.yml` と `cd-infra.yml` の
   `terraform_version` と `TERRAFORM_VERSION` は常に同一バージョンにする
   （state を書くのは CI なので CI 側の pin が正）。
3. 本ドキュメント §1 のバージョン表を合わせて更新する。
4. **Dev Containers: Rebuild Container** で反映し、`postCreateCommand` のバージョン一覧で
   確認する。

補足:

- Node.js は CI（`node-version: 24`）と同じく major のみ固定（`setup_24.x`）。minor は
  CI と同じ幅で float させる。
- Python（deadsnakes 3.14）は #110 の決定に従う（この節の対象外）。
- AWS CLI v2 / gh / Claude Code は CI のゲート対象ではないため意図的に latest。

---

## 関連ドキュメント

- [`README.md`](../README.md) — 構成・各種初期設定（Git / Claude Code / AWS SSO）の詳細
- [`CLAUDE.md`](../CLAUDE.md) — Claude Code 向けのリポジトリガイドと規約
- [sandbox.md](sandbox.md) — クラウド上での使い捨て検証・開発（`sandbox/*` 隔離ブランチ）
