# ADR-0003: #40（ドメイン拡充）・#41（認証認可）を既存モノレポ構成のまま吸収する

- **Status:** Accepted
- **Date:** 2026-07-01
- **Deciders:** itouhi
- **Related:** [Epic #46](https://github.com/iwata-jawsug-jp/devcon/issues/46), #40, #41,
  [ADR-0001](0001-record-architecture-decisions.md)

## Context

Epic #46「プロダクト化に向けた機能強化ロードマップ」の子タスクとして、#40（items CRUD の骨組みから
実ドメイン機能への拡充）と #41（Cognito/JWT による認証認可の導入）に着手する前に、現在のモノレポ構成
（`services/api` / `services/web` / `infra` の3分割、単一 ECS Fargate + ALB + RDS + CloudFront/S3）が
この2つの拡張を受け止められるか、それともサービス分割・リポジトリ分割が必要になるかを確認した。

調査した内容:

- `services/api` は router / repository / schema / db-model をリソース単位でファイル分割する構成
  （現状 `items` 系のみ）。
- `infra` はブートストラップ層と app 層の2層、app 層は `api.tf` / `web.tf` / `db.tf` / `network.tf` /
  `shared.tf` / `endpoints.tf` のフラットな Terraform ファイル構成（モジュール化はまだ無い）。
- `ci.yml` の `changes` ジョブは `services/api/**` / `services/web/**` / `infra/**` でパスフィルタ
  しており、各エリアの変更が他エリアのジョブを巻き込まない設計になっている。
- 既存 ADR（0001, 0002）にモノレポ境界を見直す動機の記述は無く、#46 本文もマイクロサービス化や
  リポジトリ分割を示唆していない。

## Decision

**#40・#41 とも、新しいサービス境界やリポジトリ分割を導入せず、既存の3分割モノレポ構成の中で
拡張する。**

- **#40（ドメイン拡充）:** 新しいドメインリソースは `items` と同じパターン（router + repository +
  schema + db-model をリソース単位で追加）で実装する。新しいデプロイ単位は作らず、単一の ECS
  Fargate サービスのまま拡張する。
- **#41（認証認可）:** Cognito は新しい「サービス」ではなく共有インフラとして `infra/` の app 層に
  Terraform リソースを追加する形で導入する（例: `cognito.tf`）。API 側は `Depends` ベースの検証層を
  既存ルーターに被せる形とし、認証専用のマイクロサービスは作らない。

## Consequences

- **良い面:** サービス分割・リポジトリ分割に伴う運用コスト（デプロイパイプライン増設、クロスサービス
  契約管理、CI マトリクス複雑化）を避けられる。既存の1 issue → 1 focused PR の運用、
  `make gen-types` による契約駆動、CI のパスフィルタ設計をそのまま活かせる。
- **将来の負担（今は許容、規模が育ったら内部整理を検討）:**
  - `services/api` のリソース数が数個を超えたら、ルーター/リポジトリをサブパッケージ化
    （例: `routers/items/`）する内部整理が要る可能性がある。これはモノレポ境界の変更ではなく
    ファイル配置の整理に留まる。
  - `infra/*.tf` がフラットなまま肥大化した場合、Terraform module 化（例: `modules/cognito/`）を
    検討する局面が来る可能性がある。これも既存の2層構成（bootstrap / app）を維持したままの内部整理。
- **再検討トリガー:** #40 のドメインが将来的に独立したスケーリング要件・独立チームでの開発が必要な
  規模になった場合、または #41 の認証基盤を他プロダクトと共有する必要が生じた場合は、サービス分割を
  別 ADR で改めて検討する。
