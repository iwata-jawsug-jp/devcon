# ADR-0029: サービス構成変更（追加・置き換え）の判断基準

- **Status:** Accepted
- **Date:** 2026-08-01
- **Deciders:** Itou Hideki
- **Audience:** publish, generate
- **Related:** #696、バックエンド言語追加の仕組み化 提案書、
  スキャフォールド後のサービス差し替え 提案書、
  [ADR-0003](0003-keep-monorepo-through-domain-and-authn-expansion.md)、
  [ADR-0004](0004-rename-services-by-role-and-nest-backend-by-language.md)、
  [ADR-0012](0012-reusable-workflow-in-repo-tag-versioned.md)、
  [ADR-0024](0024-adopt-go-as-second-backend-language.md)

## Context

`services/backend/`・`services/frontend/` の構成を変える判断（新しい実装を**追加**する、既存の
実装を**置き換える**）は、これまで個別の提案書の中でしか基準が言語化されてこなかった。

- ADR-0024（Go を第二バックエンド言語として追加した決定）は、その判断の**実例**であって
  一般化された基準ではない。
- `#696`（バックエンド言語追加の仕組み化 提案書、未issue化・検討中）§4.1 は、ADR-0024 を
  土台に「追加」の判断基準（役割分担・実行基盤・不変条件・却下パターン）を整理したが、
  提案書内にとどまり ADR として採択されていない。
  提案書）は、backend/frontend の**置き換え**を検討する中で、同じ基準が「追加」だけでなく
  「置き換え」にも通用する形に一般化できることを確認した（同提案書 §4.5）。あわせて、
  置き換え後も失われてはならない不変条件を2点、実装調査から新たに特定した（同提案書
  §4.2・§4.4）: フロントエンド品質ゲートのパリティと、backend Dockerfile の最低限契約。

このままでは「追加」と「置き換え」で別々の基準が育ち、どちらも正式な決定として記録されない
状態が続く。両者に共通する判断の**原則**を、単一の ADR として確立する必要がある。

なお、この ADR は判断の原則のみを記録する。「置き換え」の具体的な手順・契約点の照合表は
`docs/service-replacement-guide.md`（Sub-issue C、本 ADR 成立後に着手）に委ね、ADR-0024 が
実装手順を列挙せず決定のみを記録するスタイルを踏襲する。

## Decision

`services/backend/`・`services/frontend/` の実装を追加または置き換える際は、以下の基準を
満たすことを判断の前提とする。

1. **役割分担が変わらないこと。** backend であれば同期 REST / 非同期イベント駆動という
   既存の役割区分（ADR-0024）を維持したまま追加・置き換えを行う。役割区分そのものを
   変える（例: 新しい役割カテゴリを設ける）場合は本 ADR の対象外とし、別途 ADR を起こす。
   新しい実装は「既存の実装の役割拡張では表現できない新しい役割」を担う場合にのみ追加する
   — 既存実装のリファクタで足りるなら追加しない。
2. **実行基盤が役割相応のまま変わらないこと。** ECS Fargate（常駐・同期）/ Lambda
   （サーバーレス・非同期）という役割ベースの割り当て（ADR-0024）を維持する。新しい実装に
   既存実装と重複する実行基盤を割り当てない（ADR-0024 却下案「Go を ECS Fargate にも
   載せる案」の一般化）。
3. **スキーマ権威の扱いを明示すること。** DB スキーマの権威は Alembic（Python）に一元化
   したまま動かさないことを既定とする。Alembic を削除する場合（backend Python を置き換える
   場合）は、`Makefile` の `gen-schema` ターゲットが持つ `migrate` ステップの移譲先
   （新実装側のマイグレーションツール）を決定に明示すること。`gen-schema` の他の3段
   （`db-up` / `pg_dump --schema-only` / `sqlc generate`）との結合は浅く、パイプライン
   全体の作り直しは不要（service-replacement-proposal.md §3.1 で確認済み）。
4. **契約統一を維持すること。** API 契約は OpenAPI に一本化し、`make gen-types` が単一
   コマンドで呼べる状態を維持する。各実装は自分の OpenAPI JSON を出力するコマンドを1つ
   持つことを標準契約とする（Go の `go run ./cmd/api openapi` が既存パターン）。
5. **置き換え後も維持すべき不変条件を満たすこと。**
   - **frontend 品質ゲートパリティ**: 新しい `reusable-frontend-<framework>.yml` は、
     少なくとも型チェック・アクセシビリティの自動チェック（axe 相当）・パフォーマンス予算
     （Lighthouse CI 相当）・認証込み E2E（ADR-0008 の live-smoke パターン）の4種類のゲートを
     備えること。ツール自体が変わってもゲートの「種類」を失わない。
   - **backend Dockerfile の最低限契約**: 新しい backend 実装は、(1) `0.0.0.0` で
     `var.api_port` を LISTEN する、(2) `var.api_health_check_path` は認証不要で応答する、
     (3) 依存関係をビルド時に完全解決する（ランタイムに internet 経路がないため）、
     (4) 実行時に到達できる AWS サービスは VPC エンドポイント経由のもの（S3・ECR・
     CloudWatch Logs・Secrets Manager・Cognito IDP・X-Ray）に限る、(5) マイグレーションは
     `containerOverrides` によるコマンド差し替えに対応する、(6) `API_*` の環境変数キー名を
     そのまま読み取る、の6点を満たすこと。
   - いずれも詳細な手順・検証表は `docs/service-replacement-guide.md`（Sub-issue C）に委ねる。

却下パターン（新しい実装が満たしてはいけない条件）: 実行基盤の重複、スキーマ権威の分散、
契約の実装依存化（OpenAPI 以外を正とする、または `make gen-types` に統合できない形にする）
の3つを、追加・置き換えいずれの提案でも不採用とする。

## Consequences

- 良い面: 「追加」と「置き換え」で判断基準が分岐せず、単一の ADR を根拠に議論できる。
  新しい提案（backend 3言語目の追加、frontend フレームワーク変更など）が出るたびに
  基準を再発明する必要がなくなる。
- 悪い面・負担: 基準が一般化された分、個別ケースへの当てはめ（役割分担の線引き、
  不変条件の充足確認）には引き続き判断力が要る。機械的なチェックだけでは完結しない
  部分は `service-replacement-check` スキル（提案書 §4.6）のような診断支援に委ねる。
- `#696` は本 ADR の**「追加」の実例**として、`service-replacement-proposal.md` は
  **「置き換え」の実例**として扱う（ADR-0024 と `#696` の関係と相似形）。両提案書は
  本 ADR を書き換えず、本 ADR を土台にした個別ケースの記録として残す。
- 再検討トリガー: 「追加」でも「置き換え」でもない第三の構成変更パターン（例: 既存実装の
  役割区分自体を変える）が実際に必要になった場合、または本 ADR の基準を適用しても
  判断がつかないケースが繰り返し発生した場合は、本 ADR を見直す。
