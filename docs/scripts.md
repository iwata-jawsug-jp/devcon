# `tools/script/` スクリプト一覧

`tools/script/` に置かれた各シェルスクリプトの用途・使い方をまとめた索引。個々の背景・設計判断は
スクリプト冒頭のコメント、および各節でリンクする詳細ドキュメントを正とする（本書は「どれを
いつ使うか」を素早く引くための一覧）。`make help` で `Makefile` から呼べるものは合わせて記載する。

新しいスクリプトを追加したら、この表と該当する詳細ドキュメント（あれば）の両方を更新すること。

## 開発環境セットアップ

| スクリプト                   | 用途                                                                                                                                          | 実行方法                                      |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| `check-devenv-setup.sh`      | 初回セットアップ項目（ツール導入・各サービスログイン・GitHub Rulesets 等）を一括確認する。CI では使わない。                                   | `make check-setup`                            |
| `check-repo-vars.sh`         | リポジトリ変数（`vars.*`）の「workflow参照」「ドキュメント記載」「実登録」の3者の整合をチェックする。                                         | `make check-repo-vars`                        |
| `claude-codespaces-setup.sh` | GitHub Codespaces 新規作成直後、Claude Code の初回オンボーディング/信頼ダイアログを事前承認する。                                             | `make claude-setup`                           |
| `aws-sso-setup.sh`           | AWS SSO プロファイルの初期設定・ログイン（`login`）と、AWS MCP Server 用 `agent-mcp` ロールへの assume-role プロファイル追加（`agent-mcp`）。 | `./tools/script/aws-sso-setup.sh --help` 参照 |

詳細: [development-environment.md](development-environment.md) §3、[aws-temporary-credentials.md](aws-temporary-credentials.md) §5。

## インフラ bootstrap・アプリ層変数

| スクリプト             | 用途                                                                                                                                                                                       | 実行方法                                           |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------- |
| `bootstrap.sh`         | `infra/bootstrap`（state バケット・OIDC・CI用IAMロール）の初期化・更新・書き込み・破棄・別マシンへの引き継ぎ。`init`/`update`/`write`/`destroy`/`adopt`/`recover` の各サブコマンドを持つ。 | `./tools/script/bootstrap.sh <command> --help`     |
| `write-cd-app-vars.sh` | 対象環境（`dev`/`prod`/`sandbox`）の terraform output から、`cd-app.yml`/`cd-app-sandbox.yml` が必要とするアプリ層のリポジトリ変数12個を登録（`--clear` で削除）。                         | `./tools/script/write-cd-app-vars.sh <env> --help` |

詳細: [infrastructure.md](infrastructure.md)、[repository-variables.md](repository-variables.md)。

## リポジトリ設定・ガバナンス（GitHub Rulesets / デフォルトブランチ）

| スクリプト                  | 用途                                                                                                                                                                                                                                                                                                                     | 実行方法                                                     |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------ |
| `update-branch-rulesets.sh` | `main-ci-required`（必須ステータスチェック）・`sandbox-isolation`（`guard` 必須化）の各 GitHub Ruleset を、`ci.yml`/`sandbox-guard.yml` の必須ジョブ構成に合わせて作成・更新する。                                                                                                                                       | `./tools/script/update-branch-rulesets.sh --help`            |
| `rename-default-branch.sh`  | デフォルトブランチ名を変更する汎用ツール（任意の旧名→新名）。既定では `.github/workflows/*.yml` 内のトリガー参照（`branches: [<old>]` 等）の書き換えのみ（ワーキングツリー編集・コミットはしない）。`--rename` を付けたときのみ GitHub 上のブランチを実際にリネームする（`default_branch` の付け替えを含む破壊的操作）。 | `./tools/script/rename-default-branch.sh <old> <new> --help` |

どちらも admin 権限が必要（`check-devenv-setup.sh`/`check-repo-vars.sh` が使う読み取り限定PAT
`GH_CHECK_SETUP_TOKEN` ではスコープ不足）。まず `--dry-run` で送信内容・変更予定箇所を確認してから
実行することを推奨する。

詳細: [infrastructure.md](infrastructure.md)「ブランチ保護（GitHub Rulesets）」、
[sandbox.md](sandbox.md)「GitHub ルールセット」、[org-rulesets.md](org-rulesets.md)。

### `rename-default-branch.sh` の使い方（例: `main` → `trunk`）

```bash
# 1. まず dry-run で変更予定箇所を確認する（ファイル書き換え・GitHub操作なし）
./tools/script/rename-default-branch.sh main trunk --dry-run

# 2. workflow ファイルのトリガー参照を書き換える（ワーキングツリー編集のみ）
./tools/script/rename-default-branch.sh main trunk
git diff .github/workflows/
# -> 通常のPRフローでレビュー・マージする（このリポジトリの main は
#    org-baseline ルールセットで直push禁止・PR必須のため）

# 3. 上記PRのマージ後、GitHub 上のブランチを実際にリネームする
./tools/script/rename-default-branch.sh main trunk --rename
# -> 表示されるローカルクローンの追従手順（git branch -m / git remote set-head 等）を
#    自分・他の共同作業者のクローンに適用する
```

`.github/workflows/` 配下のトリガー参照以外（コメント中の言及、`docs/`・README 等の文章、
Terraform 側の OIDC trust policy リテラルなど）は対象外。dry-run 実行時に表示される
「手動確認推奨」の一覧を見て、必要な箇所は別途手で直すこと。

## スキャフォールド・公開

| スクリプト           | 用途                                                                                                 | 実行方法                                                    |
| -------------------- | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| `verify-scaffold.sh` | `copier.yml` から実際にプロジェクトを生成し、生成物（除外リスト・sed置換）が壊れていないか検証する。 | `make scaffold-verify`（CI: `ci.yml` の `scaffold` ジョブ） |

詳細: [scaffold-cli.md](scaffold-cli.md)。


## 関連ドキュメント

- [development-environment.md](development-environment.md) — Dev Container / 初回セットアップ全体の流れ。
- [infrastructure.md](infrastructure.md) — Terraform 2層構成・CI/CD・ブランチ保護。
- [repository-variables.md](repository-variables.md) — リポジトリ変数の一覧と登録経路。
