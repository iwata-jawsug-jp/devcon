# ADR-0026: Go worker（案5: 非同期/イベント駆動）のインフラ構成を確定する

- **Status:** Accepted
- **Date:** 2026-07-25
- **Deciders:** Itou Hideki
- **Related:** [ADR-0024](0024-adopt-go-as-second-backend-language.md)、#639、#640、PR #648、
  [docs/sandbox.md](../sandbox.md)

## Context

ADR-0024 は Go バックエンドの呼び出し方式を**ハイブリッド**（非同期 = SQS/EventBridge/S3、
内部サービス間 = VPC Lattice、外部同期 = CloudFront → Lambda Function URL）に決定し、
「実装（インフラ構成の確定）時に構成 ADR を起こす」とだけ約束していた。issue #640（Epic
#636 Phase 3）はこの 3 経路すべてを `sandbox/*` で実機検証するスコープだったが、
**案5（非同期/SQS→Lambda）のみを実装・検証し、案6（VPC Lattice）・案1
（CloudFront→Function URL）・#640 自体の完了条件（構成 ADR 一式・sandbox teardown）は
実装保留**とすることを決定した（2026-07-25、優先度判断）。

そのため本 ADR は #640 が本来求めていた「3 経路の確定構成」ではなく、**案5 単体の確定構成
のみ**を対象とする。案6・案1 を実装する段になったら、それぞれ別の構成 ADR を起こす
（本 ADR はその前例・雛形として使える）。

`sandbox/640-go-worker-sqs-lambda` ブランチで、以下を実機（AWS account 730335427670,
`ap-northeast-1`）で確認済み: sandbox 環境のゼロからの再構築（destroy → apply → worker
Lambda デプロイ）、SQS 経由のメッセージ処理から DB 反映・CloudWatch Logs 確認までの
End-to-End 経路、および `ci_deploy` に必要な IAM 権限（PR #648 で main へ反映済み）。
ただし `infra/worker.tf` 等のリソース定義自体は、`docs/sandbox.md` の隔離ポリシー
（sandbox は dead end、非 sandbox ブランチへはマージしない）どおり sandbox 限定のまま
残り、今回 main へは反映していない。

## Decision

案5（`services/backend/go/cmd/worker`, SQS トリガー）の確定インフラ構成は以下のとおり
（`sandbox/640-go-worker-sqs-lambda` の `infra/worker.tf` に実装済み、内容は sandbox 限定）。

- **実行基盤:** コンテナイメージ Lambda（`package_type = "Image"`）、ベースイメージ
  `public.ecr.aws/lambda/provided:al2023`、arm64。`aws-lambda-go` の `lambda.Start()` が
  Runtime API ループ自体を実装するため、LWA（Lambda Web Adapter）層は不要 —
  LWA は `cmd/api` の外部 HTTP エントリポイント（案1、未実装）専用とする。
- **トリガー:** SQS（`aws_lambda_event_source_mapping`）、バッチハンドラで
  `BatchItemFailures` により失敗レコードのみを個別報告（全体再試行を避ける標準パターン）。
  専用 DLQ（`maxReceiveCount = 3`）で最終失敗メッセージを保持（14 日、SQS 最大値）。
- **ネットワーク:** VPC アタッチ、ECS と同じ `db` セキュリティグループパターンで RDS へ
  直結。**RDS Proxy は導入しない**（Lambda 1 実行環境 1 接続、複数 Lambda がプール接続を
  必要とする段階まで意図的に延期 — ADR-0024 提案書 §4.3 の設計どおり）。
- **シークレット:** ECS はタスク定義の `secrets` フィールドで注入されるが、Lambda に
  同等の仕組みはないため、Lambda 自身のランタイムコード（`cmd/worker/main.go`）が
  Secrets Manager から実行時に取得する。
- **IAM:** 実行ロールは `AWSLambdaVPCAccessExecutionRole`（AWS 管理）+ SQS ポーリング用
  インラインポリシー（キュー ARN スコープ）+ Secrets Manager 読み取り。`ci_deploy` 側は
  Lambda 関数・event source mapping・SQS キューの CRUD+タグ管理、
  `iam:PassRole`（`lambda.amazonaws.com` 向け）、ENI クリーンアップ用
  `ec2:DeleteNetworkInterface` を新設・追加（`infra/bootstrap/iam-ci-deploy-{messaging,
network,iam}.tf`、PR #648 で main へ反映済み、案5専用ではなく将来の Lambda 全般に
  再利用可能）。
- **デプロイ:** `cd-app-sandbox.yml` の `worker-deploy` ジョブ（`reusable-worker-deploy.yml`）が
  `docker/build-push-action` で `--platform linux/arm64 --provenance=false --sbom=false`
  ビルド・ECR push 後、`aws lambda update-function-code` で更新。**buildx の既定である
  OCI マルチマニフェスト（provenance/SBOM attestation 付き）は Lambda の
  `UpdateFunctionCode` が拒否する**ため、両方明示的に無効化する必要がある（実機確認）。
- **初回 apply 制約:** `CreateFunction`（`package_type=Image`）はイメージの実在を同期的に
  検証するため（ECS の `RegisterTaskDefinition` と違い非同期タスク起動時ではない）、
  空の ECR リポジトリに対する最初の apply は必ず失敗する。`infra/bootstrap/` 自体が
  人力での初回適用を要求するのと同じ精神で、**ECR リポジトリ作成後・初回 apply 前に
  `:bootstrap` タグの実イメージを手動で push する**ワンタイム手順が必要（`infra/worker.tf`
  の `data.external.worker_current_image` コメントに詳細）。
- **可観測性:** 構造化ログ（`slog` JSON）の correlation ID に SQS `MessageId` を使用。
  OpenTelemetry は Lambda のフリーズ対策として invocation ごとに `ForceFlush` する
  （`services/backend/go/CLAUDE.md` 記載の既定パターンをそのまま踏襲、案5固有の決定はなし）。

却下案:

- **RDS Proxy を最初から導入する案**は、現時点で Lambda が 1 関数のみでプール接続の必要性が
  実測されていないため時期尚早と判断し不採用（複数 Lambda が DB を使う段階で再検討）。
- **`cmd/api` と同じ Lambda Web Adapter 層を worker にも載せる案**は、worker が HTTP
  サーバーではなくイベントハンドラのみのため、不要なプロセス起動オーバーヘッドを
  増やすだけで不採用。
- **buildx の既定（provenance/SBOM 付き）のまま push する案**は、Lambda の
  `UpdateFunctionCode`/`CreateFunction` が実際にそのイメージ形式を拒否する
  （実機確認、`InvalidParameterValueException` 相当のマニフェストエラー）ため不採用。

## Consequences

- 良い面: SQS→Lambda の非同期経路が実 AWS で End-to-End 動作することを確認済み。
  `ci_deploy` の IAM 権限（Lambda/SQS/ENI クリーンアップ）は案5専用ではなく、
  今後 Go 側に追加する他の Lambda（案1・案6 含む）にもそのまま再利用できる形で
  main に先行反映済み。
- 悪い面・負担: `infra/worker.tf` 等の実際のリソース定義は sandbox 限定のままであり、
  本番相当（非 sandbox）環境へこの構成を実装する作業は本 ADR の対象外・別途の実装
  issue が必要（#640 の残作業は保留中）。RDS Proxy 未導入のため、将来 2 つ目の
  Lambda が DB へ直結する段階で接続数の再設計が必要になる。
- 再検討トリガー: (a) 案6（VPC Lattice）・案1（CloudFront→Function URL）の実装に着手する
  時点でそれぞれ別の構成 ADR を起こす。(b) 2 つ目以降の Lambda が RDS へ直結する必要が
  出た時点で RDS Proxy 導入を再検討する。(c) この構成を非 sandbox（dev/prod 相当）
  環境へ実装する段階になった時点で、sandbox 限定だった `infra/worker.tf` を本番相当の
  ブランチへ書き起こす作業が必要になる。
