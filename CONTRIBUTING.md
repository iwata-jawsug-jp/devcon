# コントリビューションガイド

`devcon` への貢献ありがとうございます。このリポジトリは Dev Container 上で
Terraform / AWS と Python・Node/TypeScript を扱うモノレポです。開発を始める前に、
[`README.md`](README.md) と [`docs/development-environment.md`](docs/development-environment.md)
に目を通してください。

## 行動規範

このプロジェクトは [行動規範（CODE_OF_CONDUCT.md）](CODE_OF_CONDUCT.md) を採用しています。
参加する全員がこれを尊重することを期待します。

## 開発環境のセットアップ

1. VS Code でリポジトリを開き、**Dev Containers: Reopen in Container** でコンテナに入る。
2. 初回セットアップを実行する。

   ```bash
   make setup     # Python(uv) + Node(npm) 依存と pre-commit フックを導入
   ```

詳細は [開発環境ガイド](docs/development-environment.md) を参照してください。

## 開発フロー

1. `main` から作業ブランチを切る。

   ```bash
   git switch -c feat/<短い説明>     # 例: feat/add-vpc-module
   ```

2. 変更を加え、コミット前にローカルで品質チェックを通す。

   ```bash
   make fmt      # 整形（terraform fmt / ruff format / prettier）
   make lint     # 静的解析（tflint / ruff+mypy / eslint+tsc）
   make test     # テスト（pytest / node --test）
   make security # Trivy + Checkov で infra をスキャン（infra 変更時）
   ```

3. プッシュして Pull Request を作成する。`main` への直接コミットは避けてください。

## ブランチ命名

| プレフィックス | 用途 |
| --- | --- |
| `feat/` | 機能追加 |
| `fix/` | バグ修正 |
| `docs/` | ドキュメント |
| `chore/` | 雑務・依存更新・設定 |
| `refactor/` | 挙動を変えないリファクタ |

## コミットメッセージ

[Conventional Commits](https://www.conventionalcommits.org/) に従います。

```
<type>: <subject>

例:
feat: persist devcontainer user settings via docker volumes
fix: handle missing tfvars in tf-plan
docs: add development environment usage guide
```

`type` は `feat` / `fix` / `docs` / `chore` / `refactor` / `test` / `ci` など。

## コーディング規約

CLAUDE.md と各ツール設定に準拠します。

- **Python**（`services/api/`）: ruff（line length 100 / `py312` target）、mypy strict、型ヒント必須。
  `python`/`pip` を直接使わず必ず `uv run` 経由。
- **TypeScript**（`services/web/`）: strict mode、ESM（`type: module`）、eslint + prettier。
- **Terraform**（`infra/`）: 2-space indent、`terraform fmt`、リソースのタグは provider の
  `default_tags` で付与。
- **秘密情報は絶対にコミットしない**。`*.tfvars` / `.env` / 認証情報 / 鍵は `.gitignore` 済み。
  テンプレートは `*.example` をコミットする。

## コミット前の品質ゲート

`make hooks`（= `pre-commit install`）で有効化される pre-commit がコミット時に自動実行されます。

- 汎用: 末尾空白・改行・大容量ファイル・秘密鍵検出
- Terraform: `fmt` / `validate` / `tflint` / `checkov` / `trivy`
- Python: `ruff`（lint + format）
- Node 系: `prettier`

> `--no-verify` でのフックのバイパスは禁止です。失敗したら原因を修正してください。

## Pull Request

- 1 PR は 1 つの目的に絞る。
- 説明に **何を・なぜ** 変更したかを書く。
- `make lint` / `make test`（infra 変更時は `make security`）が通っていることを確認する。
- ユーザーに見える変更は [CHANGELOG.md](CHANGELOG.md) の `[Unreleased]` に追記する。
- レビューと CI を通過してからマージする。

## 変更履歴

ユーザーに影響する変更は [CHANGELOG.md](CHANGELOG.md) を更新してください
（[Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) 形式）。
