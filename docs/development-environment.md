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

| 種別             | ツール                                    | バージョン       |
| ---------------- | ----------------------------------------- | ---------------- |
| ベース           | Ubuntu                                    | 22.04            |
| 言語             | Python                                    | 3.14             |
| 言語             | Node.js                                   | 24（major 固定） |
| Python 管理      | uv                                        | 0.11.24          |
| スキャフォールド | copier（#294）                            | 9.17.0           |
| IaC              | Terraform / tflint                        | 1.13.0 / 0.64.0  |
| セキュリティ     | trivy / checkov                           | 0.71.2 / 3.3.2   |
| クラウド         | AWS CLI v2                                | latest           |
| その他           | gh / docker(dind) / ripgrep / Claude Code | latest           |

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

> **初回ビルドの高速化（ADR-0018）:** `devcontainer.json` の `build.cacheFrom` が GHCR に
> 事前公開されたレイヤー（`ghcr.io/iwata-jawsug-jp/devcon/devcontainer:latest`）を参照しており、
> `.devcontainer/Dockerfile` が前回公開時点と同じであれば初回ビルドがほぼ pull のみの速度になる。
> ビルドログに `ERROR: failed to configure registry cache importer` という赤い行が出ることが
> あるが、これはキャッシュ元が見つからない/未公開なだけの無害なメッセージで、ビルド自体は
> 正常に続行する（フォールバックして通常どおりビルドするだけ）。

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

`gh auth login` は初回のみ対話式（`gh auth status` で未ログインか確認できる）:

```bash
gh auth status
# You are not logged into any GitHub hosts. To log in, run: gh auth login
```

```
$ gh auth login
? Where do you use GitHub? GitHub.com
? What is your preferred protocol for Git operations on this host? HTTPS
? How would you like to authenticate GitHub CLI? Login with a web browser
```

表示された one-time code をコピーし、案内される URL
（`https://github.com/login/device`）をブラウザで開いて認証を完了する。
成功後は `gh auth status` で `Logged in to github.com account <user>` と
表示される（`~/.config/gh` はボリューム永続化のため、Rebuild Container
後も再ログイン不要）。

上記（同梱ツール・`make setup`・各ログイン）に加え、リポジトリ側で設定が必要な GitHub
Rulesets（[infrastructure.md「ブランチ保護」](infrastructure.md#ブランチ保護github-rulesets)・
[sandbox.md「GitHub ルールセット」](sandbox.md#github-ルールセットsandbox-guard-を必須化)）が
一通り完了しているかは `make check-setup`（`tools/script/check-devenv-setup.sh`）で一括確認
できる。未完了の項目は `[NG]` とその対処コマンドが表示される。

![make check-setup の実行例（全項目 [OK]、PASS: 26 / FAIL: 0）](images/make_check-setup_image01.png)

GitHub Codespaces では、Codespaces が自動で注入する既定の `gh` 認証（`GITHUB_TOKEN`）は
API によって権限が異なり、GitHub Rulesets は読めても Actions のリポジトリ変数
（`AWS_TF_STATE_BUCKET` 等）は読めない、といったケースがある（#516）。この場合 `make
check-setup`（および `make check-repo-vars`）は該当項目を「未登録」ではなく「権限不足で
確認できない」旨のスキップ表示にする（誤って未登録扱いにはしない）。また
`tools/script/bootstrap.sh write` がリポジトリ変数へ書き込む際も、同じ既定認証では
書き込み権限が無いことがある。正確に判定・書き込みしたい場合は、
`Administration: Read-only` + `Variables: Read and write`（対象リポジトリ限定・短期の
有効期限）の Fine-grained PAT を発行し、以下のいずれかで `GH_CHECK_SETUP_TOKEN` として渡す
（[ADR-0021](adr/0021-codespaces-user-secrets-for-check-setup-token.md)、
[ADR-0022](adr/0022-widen-check-setup-token-scope-for-bootstrap-write.md)）:

- **GitHub Codespaces を使っている場合（推奨）**: `github.com/settings/codespaces` で
  ユーザーシークレット `GH_CHECK_SETUP_TOKEN`（対象リポジトリ: このリポジトリ）を設定する。
  一度設定すれば、以降作成する新しい Codespace すべてに自動的に環境変数として注入され、
  Codespace を作り直しても再設定は不要になる。**既存の起動中 Codespace には反映されない
  ことがある**——反映されない場合は一度 Codespace を再起動（stop → start）するか、
  作り直すこと。
- **ローカルの Docker Desktop 経由の devcontainer など、Codespaces を使わない場合**:
  `.env.check-setup.example` の手順に従って `.env.check-setup`（git-ignored）に
  `GH_CHECK_SETUP_TOKEN=...` を用意する。

`make check-setup` / `make check-repo-vars` は用意しなくても動く（該当項目がスキップ表示に
なるだけ）。`bootstrap.sh write` は用意しなければ従来どおり gh の既定認証（≒
`GH_TOKEN=<token>` の明示指定）で書き込みを試みる。複数の経路が存在する場合は環境変数
（Codespacesシークレット）側が優先される。

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

### MCP サーバー（Claude Code、`.mcp.json`）

`docs/proposal/mcp-server-selection-proposal.md`（#566）の選定方針に基づき、project scope で
`.mcp.json` にコミットする。現時点の常時導入対象:

- **Terraform MCP Server**（HashiCorp 公式）— `infra/` での Terraform コード生成時に
  Terraform Registry のプロバイダー/モジュール最新バージョン・仕様を参照する。Docker イメージ
  （`hashicorp/terraform-mcp-server:1.1.0`、バージョンはタグ固定。`:latest` は使わない）を
  devcontainer 組み込み済みの docker-in-docker feature 経由で起動する。追加インストール不要。
  HCP Terraform/Enterprise 向けのワークスペース操作ツールは `TFE_TOKEN` 未設定のため無効
  （本リポジトリでは公開 Registry の参照のみに使う）。バージョン更新は手動（`.mcp.json` の
  タグを書き換える）。
- **AWS MCP Server**（Agent Toolkit for AWS、AWS 公式、#572）— AWS ナレッジ検索・スキル参照・
  read-only API 実行に使う。[`mcp-proxy-for-aws`](https://github.com/aws/mcp-proxy-for-aws)
  （PyPI、バージョンタグ固定、devcontainer に導入済みの `uv` に同梱される `uvx` 経由で起動、
  追加インストール不要）が SigV4 署名でエンドポイント（`https://aws-mcp.us-east-1.api.aws/mcp`
  — AWS MCP Server の対応リージョンは `us-east-1`/`eu-central-1` のみで、これはプロジェクトの
  実際の AWS リージョン `ap-northeast-1` とは無関係。実際の AWS 操作対象リージョンは
  `--metadata AWS_REGION=ap-northeast-1` で指定）にプロキシする。
  - **認証方式に注意**: AWS MCP Server は OAuth（ブラウザでのAWS Sign-in、ローカルの
    AWS CLI クレデンシャルを経由しない）と SigV4（`mcp-proxy-for-aws` 経由、AWS CLI の
    クレデンシャルチェーンを使う）の2方式がある。本リポジトリは
    [#571](https://github.com/iwata-jawsug-jp/devcon/issues/571) で新設した
    エージェント専用 IAM ロール（`ReadOnlyAccess` + guardrail Deny）を実際に経由させる
    必要があるため **SigV4 方式のみを使う**（OAuth方式だとブラウザでサインインした
    人間自身の権限で実行され、IAMロールのguardrailが意味を持たなくなる）。
  - `--profile agent-mcp`: `docs/aws-temporary-credentials.md`
    「`agent-mcp` ロールを引き受ける」節でセットアップする `~/.aws/config` プロファイル名と
    一致させている。このプロファイルが未セットアップだと `aws` MCP サーバーは認証エラーで
    動作しない。
  - `--read-only`: プロキシ層で書き込み系ツール自体を非表示にする。IAM側の
    `ReadOnlyAccess`+Denyと合わせた二重の防御。
  - **`.claude/settings.json` の `ask`（`Bash(aws:*)`）はこの MCP サーバー経由の呼び出しには
    適用されない**（MCP ツール呼び出しは Bash パターンベースの許可ルールの対象外 — Terraform
    MCP Server のツールが確認プロンプト無しで呼べている実績どおり）。Bash 経由の `aws`
    コマンドは都度確認できるが、MCP 経由は事前の IAM 側の絞り込み（上記 `agent-mcp` ロール）
    が唯一のガードレールになる、という非対称性がある。

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

### GitHub Codespaces: 新しい Codespace でも Claude Code の再ログインを省略する

上記の名前付きボリュームは**同じ Codespace 内での Rebuild Container** には効くが、
Codespace 自体を新規に作り直すと別のボリュームになるため引き継がれない。GitHub アカウント
単位で持ち回るには、[Codespaces Secrets](https://github.com/settings/codespaces)（個人設定 →
Codespaces）に登録する。登録した Secret は対象に選んだリポジトリの新しい Codespace すべてに
環境変数として自動注入され、Claude Code がそれを検出して対話ログインをスキップする。

- **Claude Pro/Max サブスクリプションを使う場合**: 認証済みの環境で `claude setup-token` を
  実行し、非対話環境向けの長期トークンを発行する（対話ログイン＝`~/.claude/.credentials.json`
  とは別の、CI/ヘッドレス環境向けの正式な仕組み）。発行したトークンを Codespaces Secrets に
  `CLAUDE_CODE_OAUTH_TOKEN` という名前で登録する。
- **Anthropic Console/API キー課金を使う場合**: Codespaces Secrets に `ANTHROPIC_API_KEY` を
  登録するだけでよい。Claude Code が API キー認証を直接使うため、そもそも対話ログイン自体が
  不要になる。

いずれも個人アカウントの Codespaces Secrets に登録すれば、このリポジトリに限らず自分が作る
任意の Codespace に引き継がれる（登録時に対象リポジトリを選べば範囲を絞れる）。

上記は認証（ログイン）のみを解決する。認証とは別に、初回起動時のオンボーディング画面と
「このフォルダを信頼しますか」トラストダイアログも新規 Codespace ごとに出る（名前付き
ボリュームは同一 Codespace 内の Rebuild にしか効かないため）。`make claude-setup`
（`tools/script/claude-codespaces-setup.sh`）を初回 `claude` 起動前に実行すると
`~/.claude/.claude.json` にオンボーディング完了・このリポジトリのトラスト承認済みを
書き込み、両方のプロンプトをスキップできる（既存ファイルがあれば他の設定は保持したまま
該当キーだけをマージする）。

### GitHub Codespaces: npm の GitHub Packages（private レジストリ）を使う

private な npm パッケージを GitHub Packages から取得する場合も、上記と同じ仕組み
（[Codespaces Secrets](https://github.com/settings/codespaces)、個人設定 → Codespaces）で
GitHub アカウント単位に持ち回れる。

1. classic PAT を発行する（`read:packages` スコープ。参照先が private リポジトリ由来の
   パッケージなら `repo` スコープも必要）。
2. 個人アカウントの Codespaces Secrets に次の2つを登録する（対象リポジトリを選べば範囲を
   絞れる）:
   - `PACKAGE_USERNAME` — GitHub ユーザー名
   - `PACKAGE_REPO_TOKEN` — 発行した PAT
3. `.npmrc`（トークンそのものは書かず、環境変数名だけを参照するためコミットしてよい）:

   ```
   @対象org:registry=https://npm.pkg.github.com
   //npm.pkg.github.com/:username=${PACKAGE_USERNAME}
   //npm.pkg.github.com/:_authToken=${PACKAGE_REPO_TOKEN}
   ```

新しい Codespace を作るたびに `PACKAGE_USERNAME` / `PACKAGE_REPO_TOKEN` が環境変数として
自動注入されるため、`npm install` がそのまま private パッケージを解決できる
（`npm whoami --registry=https://npm.pkg.github.com` で認証状態を確認できる）。
GitHub Packages の npm パッケージは `@org` または `@user` のスコープ付き名前が必須である点に
注意。

---

## 7. トラブルシューティング

| 症状                                                                               | 対処                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ツールのバージョンが出ない / コマンドが無い                                        | **Rebuild Container** を実行。直らなければイメージをクリーンビルド。                                                                                                                                                                                                                                                                                                                                                                                                        |
| AWS が `ExpiredToken` 等で失敗                                                     | `aws sso login` を再実行（トークン期限切れ）。                                                                                                                                                                                                                                                                                                                                                                                                                              |
| push が `GH007` で拒否される                                                       | identity を GitHub noreply メールに切り替え、`git commit --amend --reset-author --no-edit`。詳細は README「Git 初期設定」。                                                                                                                                                                                                                                                                                                                                                 |
| `~/.aws` などが root 所有でアクセスできない                                        | `bash .devcontainer/init-persist.sh` を手動実行（冪等）。                                                                                                                                                                                                                                                                                                                                                                                                                   |
| bash 履歴が残らない                                                                | `~/.history` ボリュームと `.bashrc` の履歴設定を確認。新規ターミナルから有効。                                                                                                                                                                                                                                                                                                                                                                                              |
| pre-commit が走らない                                                              | `make hooks`（= `pre-commit install`）を再実行。                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Docker 経由の MCP サーバー（Terraform 等）が動くがレジストリに到達できない（WSL2） | Codespaces では起きないが、WSL2 上に Docker デーモンを立てている環境では、その DNS 解決が壊れていて `registry.terraform.io` 等の外部ホストにコンテナから到達できないことがある（#570）。WSL2 側の Docker デーモンの `daemon.json` にフォールバック DNS（例: `"dns": ["1.1.1.1", "8.8.8.8"]`）を追加し、デーモンを再起動する。devcontainer 組み込みの docker-in-docker（`devcon-dind`）はこの外側デーモンの DNS 設定を引き継ぐため、devcontainer 側の追加設定は不要。 |

---

## 8. ツールバージョンの更新手順

Terraform / tflint / trivy / checkov / uv / copier のバージョンは `.devcontainer/Dockerfile`
先頭の `ARG` に集約している（#109）。上げるときは次の手順で。

1. `.devcontainer/Dockerfile` の対象 `ARG`（`TERRAFORM_VERSION` / `TFLINT_VERSION` /
   `TRIVY_VERSION` / `CHECKOV_VERSION` / `UV_VERSION` / `COPIER_VERSION`）を書き換える。
   `COPIER_VERSION` は `ci.yml` の scaffold ジョブの pin とも同時に更新する。
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
  導入する MCP サーバーの選定方針・設計（#566）
