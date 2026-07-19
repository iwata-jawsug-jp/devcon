# ADR-0020: VPC エンドポイント到達性の完全自動検出は設計のみ記録し、実装は初回の実需要まで見送る

- **Status:** Accepted
- **Date:** 2026-07-19
- **Deciders:** itouhi
- **Related:** #296, #369, [ADR-0017](0017-policy-as-code-conftest.md),
  [ADR-0007](0007-opentelemetry-adot-sidecar-for-distributed-tracing.md)

## Context

`infra/policy/network_endpoints.rego`（#296, #369 再発防止）は縮小版:
private route table に `0.0.0.0/0` が無いこと（NAT無し構成の確認）と、ハードコードした5つの
インターフェースエンドポイント（`ecr.api` / `ecr.dkr` / `logs` / `secretsmanager` /
`cognito-idp`）の存在確認のみを行う。「ECSタスクが実際に外部通信する先」と「実際に作られた
VPCエンドポイント」を突き合わせる完全な到達性検証ではない（#369時点から明記済みの限界）。

今回、実装方式を検討するにあたり `services/backend/python` を調査した結果:

- **boto3/aioboto3/aiobotocore の呼び出しは現状ゼロ件**（依存関係にも入っていない）。
- 唯一の「外部AWSサービスへの到達」は2種類:
  - **Cognito JWKS**（`src/api/auth/jwks.py`）: `https://cognito-idp.{region}.amazonaws.com/...`
    への直接HTTPS呼び出し（`jwt.PyJWKClient` 経由、boto3 ではない）。#369 の原因そのもの。
  - **RDS**: `sqlalchemy.ext.asyncio.create_async_engine` による直接 TCP/Postgres 接続
    （`asyncpg`）。VPC内ネットワーキング（SG/ルーティング）の話であり、VPCエンドポイントの
    対象外。
- 既存の6エンドポイント（`s3` gateway, `ecr.api`/`ecr.dkr`/`logs`/`secretsmanager`/
  `cognito-idp` interface、条件付き `xray`）はすべて ECS インフラ層（イメージpull・ログ出力・
  シークレット解決）または Cognito JWKS 用途で説明がつき、現状ミスマッチは無い。
- OpenTelemetry は `opentelemetry-instrumentation-fastapi` / `-sqlalchemy` のみ導入済み
  （ADR-0007）。`opentelemetry-instrumentation-botocore` 相当は無く、仮に今 boto3 呼び出しが
  あってもトレースには出ない。

**結論: 検出対象となる実際の依存が存在しないため、今「完全自動検出」の仕組みを実装しても
検証（true positive を1件も確認できない）ができない。** ADR-0017 自身が明記した教訓
（「まだ実装されていない規約を先にポリシーとして追加すると CI が壊れる／価値を生まない」）と
同じ構造の罠 — ここでは「検証対象が無いものを自動検知する仕組みを作っても、常に無風のまま
価値を生まない」という逆向きの同型リスク。

## Decision

**実装は行わず、以下の設計を記録して見送る。** 実装は「backendに最初の boto3 / AWS SDK
呼び出し（またはハードコードされた新規AWSリージョナルホスト名への直接HTTP呼び出し）が
追加されるPR」を再検討トリガーとする。

### 採用する設計（トリガー到達時に実装する内容）

1. **静的抽出スクリプト**（例: `tools/script/extract-aws-service-deps.py`）を新設する。
   - `services/backend/python/src` を対象に、Python AST で `boto3.client("<service>")` /
     `boto3.resource("<service>")` の第一引数リテラルを収集する。
   - 加えて `https?://[\w.-]+\.(?P<service>[\w-]+)\.{region}\.amazonaws\.com` 形の
     ハードコードされたAWSリージョナルホスト名も正規表現で収集する（Cognito JWKS のような
     非SDK呼び出しを捕捉するため — boto3呼び出し検出だけでは不十分）。
   - 出力: `{"app_aws_service_dependencies": ["cognito-idp", ...]}` のJSON。
2. **`cd-infra.yml` の `plan` ジョブ**で、既存の `terraform show -json tfplan > plan.json`
   ステップの直後に上記スクリプトを実行し、`jq` で1つのJSONへマージ
   （`plan.json` の `resource_changes` に `app_aws_service_dependencies` を追加する形）してから
   `conftest test` に渡す。
   - **なぜ別ファイルのまま渡さないか**: `conftest test --policy policy a.json b.json` は
     各ファイルに対して**独立に**同じポリシーを評価する（`cognito_env_injection.rego` が
     plan.json と workflow yaml を別々に評価しているのと同じ挙動）。2つのJSONの中身を
     **突き合わせる**検証をしたい場合、Rego側で相関できないため、CI側で先に1つのJSONへ
     マージしておく必要がある。
3. **新規 Rego ファイル**（`aws_service_reachability.rego`）: `app_aws_service_dependencies`
   の各サービス識別子を「必要なエンドポイント種別」（interface のサービス名サフィックス /
   S3・DynamoDBのような gateway型 / RDSのようにエンドポイント概念自体が不要、の許可リスト）
   へ手動メンテのマッピング表で変換し、対応する `aws_vpc_endpoint` が存在しなければ deny する。
   `network_endpoints.rego` の `is_app_layer_plan` ガードを共有し、無関係な入力への誤爆を防ぐ。
   - マッピング表が必要な理由: 全AWSサービスがリージョナルinterfaceエンドポイントを
     持つわけではなく（グローバルサービス等）、機械的に1:1変換できない。新しいサービスへの
     依存を追加する開発者が、このマッピング表への追記も一緒にレビューされる設計にする。
4. **（CI非ブロッキングの補完策）** 同じトリガーのタイミングで
   `opentelemetry-instrumentation-botocore` を追加し、ADR-0007 の OTel→ADOTサイドカー→X-Ray
   経路にAWS SDK呼び出しのスパンも乗せる。これは本番運用中の可観測性強化であり、
   ADR-0017 が「Policy as Codeは決定的検証・blocking」と定めた方針とは別カテゴリ
   （非決定的な実行時オブザーバビリティ）として明確に区別し、conftest のCIゲートには
   含めない。

### 見送った代替案

- **今すぐ静的抽出スクリプトだけ作って先行導入する**: 検出対象がゼロのままでは
  実際に機能するか検証できず（1件もdenyされたことがないルールが正しく動くかは
  デプロイ時まで分からない）、保守コストだけが先行する。見送り。
- **トレース（X-Ray/OTel）ベースの実行時検出を主軸にする**: ADR-0017 の「決定的な
  IaC構成検査はCI時にblockingで行う」という設計思想と相性が悪い（実行時検出は
  本質的に「壊れてから気づく」——#369と同じ失敗モードを防げない）。live-smoke
  （#376, 4th gate）が既にこの種の実運用時の破損を一定検出できる補完策として機能して
  いるため、独立した仕組みとしては優先度を下げる。

## Consequences

- **良い面:** 存在しない依存を検証するための仕組みを作らずに済み、無駄な保守コストを
  払わない。トリガー到達時にすぐ着手できるよう、抽出方式・マージ方式・マッピング表の
  必要性という設計判断はあらかじめ済ませてある。
- **トレードオフ:** トリガー（初回boto3呼び出し追加）が来るまでは、新しいAWSサービスへの
  依存が追加された際、`network_endpoints.rego` の `required_interface_endpoint_suffixes`
  への手動追記を人（またはレビュアー）が忘れずに行う必要がある——現状の縮小版ポリシーの
  制約がそのまま残る。依存の追加自体は少数のPRイベントとして起きる想定であり、
  現状の開発規模（単一backendサービス）ではこの手動運用のリスクは許容範囲と判断する。
- **再検討トリガー:**
  - `services/backend/python` に最初の boto3 / aioboto3 呼び出し、または新規の
    ハードコードされたAWSリージョナルホスト名への直接HTTP呼び出しが追加されたら、
    このADRの「採用する設計」節をそのまま実装する。
  - 上記トリガー到達前でも、AWSサービス依存が3件以上に増える、または複数人が
    `network_endpoints.rego` を編集するようになり手動リストの更新漏れが実際に
    問題になったら、トリガーを待たず前倒しで着手する。
