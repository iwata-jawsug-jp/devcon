# ドキュメント

`devcon` の補足ドキュメント置き場。

| ドキュメント                                                 | 内容                                                                                                                                                                            |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [development-environment.md](development-environment.md)     | 開発環境（Dev Container）の使い方 — 起動・初回セットアップ・日々のワークフロー・永続化・トラブルシュート                                                                        |
| [app-development.md](app-development.md)                     | アプリ開発 — バックエンド（FastAPI）/ フロントエンド（Vite + Vue 3）の構造・手順・規約・型生成                                                                                  |
| [infrastructure.md](infrastructure.md)                       | インフラ・CI/CD — Terraform 2 層構成（bootstrap / アプリ層）と GitHub Actions・OIDC                                                                                             |
| [repository-variables.md](repository-variables.md)           | リポジトリ変数一覧 — CI/CD が参照する全リポジトリ変数（`vars.*`）を横断でまとめた一覧表                                                                                         |
| [ci-cd-area-switches.md](ci-cd-area-switches.md)             | CI/CD エリア別スイッチ — frontend / backend / infra ごとに実行可否をリポジトリ変数で切り替える設定手順                                                                          |
| [aws-temporary-credentials.md](aws-temporary-credentials.md) | IAM Identity Center を使わない一時クレデンシャル発行手順 — IAM ユーザー + get-session-token / assume-role・IAM Roles Anywhere・CloudShell 経由の 4 手法                         |
| [issues.md](issues.md)                                       | Issue から実装するときのフロー — ブランチ・所見の記録・1 issue 1 PR・CI green の確認                                                                                            |
| [development-process.md](development-process.md)             | アプリケーション開発プロセス・ブランチ戦略 — 要件定義〜リリースの全体フロー、sandbox 検証要否の判定基準                                                                         |
| [sdd.md](sdd.md)                                             | 仕様駆動開発（SDD）ワークフロー — cc-sdd `/kiro-*` スキル・`.kiro/` 構成・spec→`docs/` 昇格・CLAUDE.md 保護                                                                     |
| [requirements/](requirements/)                               | 確定要件の保管庫 — リリース済み機能の要件を `.kiro/specs/` から昇格して置く                                                                                                     |
| [design/](design/)                                           | 基本設計の図表方針＋確定設計の保管庫 — Mermaid を既定とし、AWS 構成図は `diagrams` / draw.io を補助に使う                                                                       |
| [sandbox.md](sandbox.md)                                     | sandbox 開発環境 — `sandbox/*` 隔離ブランチで CI/CD 検証・アプリ開発・環境構築を実 AWS で。ゴールデンパスの一部として公開対象                                                   |
| [frontend-frameworks-demo.md](frontend-frameworks-demo.md)   | フロントエンド複数フレームワーク比較デモ（計画） — sandbox ブランチで `services/frontend/`（本番 Vue）とは別に、学習・比較目的で複数フレームワーク実装を並べる構成案            |
| [ai-instructions.md](ai-instructions.md)                     | AI 開発ルールの同期手順 — `CLAUDE.md` と Copilot 用 `.github/instructions/*` のミラーをドリフトさせない運用                                                                     |
| [adr/](adr/)                                                 | Architecture Decision Record — インフラ・アーキ上の重要判断を「なぜそう決めたか」で記録（[ADR-0001](adr/0001-record-architecture-decisions.md) ＋ [template](adr/template.md)） |
| [images/](images/)                                           | ドキュメントから参照される図版 — 例: [design/README.md](design/README.md) が使う AWS 構成図（draw.io）                                                                          |

リポジトリ全体の概要と各種初期設定は直下の [`../README.md`](../README.md) を参照。
