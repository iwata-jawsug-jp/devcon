# ADR-0024: backend の第二言語として Go を採用し `services/backend/go/` に配置する

- **Status:** Accepted
- **Date:** 2026-07-24
- **Deciders:** Itou Hideki
- **Related:** [ADR-0004](0004-rename-services-by-role-and-nest-backend-by-language.md)、Go バックエンド採用提案書

## Context

backend は現在 Python（FastAPI）のみ（`services/backend/python/`）。ADR-0004 で
`services/backend/` を言語別にネストする構造を先に決めており、非 Python バックエンドを
併置する受け皿は既にある。ここに Go を第二の開発言語として実際に導入したい。

Go を選ぶ動機は、(1) 静的シングルバイナリによる小さく速いコンテナ（distroless で
10〜20 MB 級）と AWS Lambda 適性（コールドスタートが速く `provided.al2023` + arm64 が
公式推奨）、(2) `go test` / `go vet` / govulncheck など標準ツールチェーンが厚く、既存の
fmt / lint / test / security の品質ゲート体系に低コストで載ること、(3) 学習・比較の題材
としての価値（本リポジトリはゴールデンパス実証の場でもある）。

制約は、本リポジトリの根幹ルールである「FastAPI の OpenAPI スキーマが API 契約の唯一の
ソースで、フロントエンド型は `make gen-types` で生成する」体系を言語追加後も壊さない
こと、および既存 CI/CD（エリア別スイッチ、reusable workflow、第 4 ゲート）に対称に
組み込めることである。

## Decision

backend の第二言語として Go を採用し、`services/backend/go/` に配置する。

- 配置は ADR-0004 の言語別ネスト構造に従う。`services/backend/python/` は併存させ、
  すみわけは**役割分担型**とする（2026-07-24 決定）: 同期 REST = Python、非同期・
  イベント駆動 = Go。
- 「コードから OpenAPI を自動生成し `/openapi.json` で配信する」構成を必須要件とし、
  API 契約と型生成の仕組みを言語非依存に保つ。`make gen-types` は Python / Go 両サービスの
  OpenAPI を**統合**して型生成する方式とする（2026-07-24 決定）。
- 技術スタックは Go バックエンド採用提案書
  のとおり決定（2026-07-24）: **huma v2 + chi**、pgx + sqlc、golangci-lint + govulncheck。
  Lambda 実装方式は外部呼び出し（HTTP）= **Lambda Web Adapter**、イベント駆動 =
  **aws-lambda-go ネイティブ**。スキャフォールド CLI（ADR-0010/0011）のテンプレートにも
  Go バックエンドを含める。
- DB スキーマの設計・管理（マイグレーション）は Python 側の Alembic に一元化し、Go は
  スキーマの読み取り専用の消費者とする（提案書 §2.3.1。Go 側にマイグレーションツールは
  導入しない）。スキーマの権威を 2 つにしないための決定であり、Python バックエンドを
  撤退させる場合に移管方式を再検討する。
- Go サービスのデプロイ先は **AWS Lambda 専用**とする（2026-07-24 追記）。ECS Fargate は
  Python バックエンド専用のまま変更せず、「常駐 = Python/ECS、サーバーレス = Go/Lambda」と
  実行基盤ごと役割を分ける。
- 呼び出し方式は**ハイブリッド**に決定（2026-07-24、提案書 §4.3）: 外部呼び出しは
  CloudFront → Lambda Function URL（OAC）、非同期は SQS / EventBridge / S3 トリガー、
  内部サービス間は VPC Lattice。API Gateway（HTTP API / REST API）と ALB ターゲット
  グループは不採用。実装（インフラ構成の確定）時に構成 ADR を起こす。

却下案: バックエンド言語を Python 単一のまま維持する案は、多言語構成の実証という
リポジトリの目的（ADR-0004 の前提）に合わないため不採用。Fiber 等 fasthttp 系の採用は
標準ライブラリ互換（Lambda Web Adapter で無改変 Lambda 化する前提）を失うため不採用。
Go を ECS Fargate にも載せる案は、Python と実行基盤が重複し 2 言語構成の住み分けが
曖昧になるため不採用（Lambda 専用とする）。

## Consequences

- 良い面: 小さく安全な実行イメージ、Lambda を含むデプロイ先選択肢の拡大、多言語
  monorepo 運用（ADR-0004）の実証が進む。
- 悪い面・負担: 品質ゲート（Makefile / pre-commit / CI の 3 層）・依存更新（dependabot）・
  ドキュメント（CLAUDE.md、app-development.md）の維持対象が 1 言語ぶん増える。
  Python 側と機能重複する期間はどちらが正かの管理が必要。
- 再検討トリガー: Go 側の縦切り実装（提案書 Phase 2〜3）で `gen-types` 連携またはデプロイ
  に本質的な障害が出た場合、あるいは 2 言語維持のコストが実益を上回ると判断した場合は、
  本 ADR を見直す。
