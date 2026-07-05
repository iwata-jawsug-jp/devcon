# ADR-0007: 分散トレーシングは OpenTelemetry 計装 + ADOT コレクタサイドカー + AWS X-Ray を採用する

- **Status:** Accepted
- **Date:** 2026-07-05
- **Deciders:** itouhi
- **Related:** #42, [ADR-0006](0006-dora-deployment-frequency-and-lead-time-definitions.md)

## Context

#42（可観測性の整備）で残っていた「分散トレーシング（OpenTelemetry / AWS X-Ray）の API への
導入」を実装する。完了条件は「トレースで 1 リクエストを web→api→DB まで追える」こと。

api は ECS Fargate（`infra/api.tf`）で動く FastAPI アプリ、DB は RDS PostgreSQL
（SQLAlchemy async）。Fargate タスクは private subnet に置かれ、NAT ゲートウェイは無く、
VPC インターフェースエンドポイント（`infra/endpoints.tf`: ECR/CloudWatch Logs/Secrets
Manager）経由でのみ AWS API に到達できる。トレースデータを外部に送るには、この構成に
合わせた到達経路が必要になる。

### 選択肢の比較

| 観点                     | A. OpenTelemetry SDK + ADOT コレクタ（サイドカー）→ X-Ray                                                                                                                    | B. `aws-xray-sdk`（X-Ray 専用）+ X-Ray デーモン（サイドカー）                               | C. アプリから直接 X-Ray API を呼ぶ（サイドカーなし）                                                                                                                  |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 計装コードのベンダー依存 | ◎ OpenTelemetry は業界標準。将来 X-Ray 以外（Jaeger/Tempo/vendor SaaS）に輸出先を変えてもアプリの計装コードは変更不要（コレクタの設定だけ変える）                            | △ `aws-xray-sdk` の API・伝播フォーマットに直接依存。乗り換え時はアプリコード側の変更が要る | ◎ SDK 選定自体は自由（が、結局サイドカー無しでも下記の理由で解決しない）                                                                                              |
| Fargate での実現性       | ○ サイドカーコンテナが必要（`amazon/aws-otel-collector` 公式イメージ、`AOT_CONFIG_CONTENT` 環境変数で設定注入、追加ビルド不要）                                              | ○ サイドカーコンテナが必要（`amazon/aws-xray-daemon`）                                      | ✗ `aws-xray-sdk` はデーモンへの UDP 送信が前提でデーモンレスモードが無い。X-Ray への直接 OTLP 送信は SigV4 署名を自前実装する必要があり、公式ライブラリの後ろ盾がない |
| ネットワーク到達性       | ○ サイドカーは同一タスク内（`awsvpc`、localhost）→ アプリからの追加到達性は不要。コレクタ→X-Ray は VPC インターフェースエンドポイント（`xray`）を新設すれば NAT 無しで到達可 | ○ 同上（コレクタの代わりにデーモン）                                                        | ✗ アプリコンテナ自身が `xray` エンドポイントへの到達性を持つ必要がある点は同じで、利点なし                                                                            |
| ログ/トレース相関        | ○ `trace_id`/`span_id` を構造化ログ（#42 済み実装）に載せやすい標準API                                                                                                       | △ 可能だが独自形式                                                                          | -                                                                                                                                                                     |
| 運用実績・ドキュメント   | ◎ AWS 公式ドキュメントに Fargate+ADOT+X-Ray の構成が明記                                                                                                                     | ◎ 古くからある実績パターン                                                                  | ✗ 非標準・自前実装のリスクが高い                                                                                                                                      |

## Decision

**OpenTelemetry SDK（`opentelemetry-instrumentation-fastapi` / `-sqlalchemy`）でアプリを計装し、
ECS タスクに ADOT（AWS Distro for OpenTelemetry）コレクタをサイドカーコンテナとして追加、
AWS X-Ray へエクスポートする（案 A）。**

- **計装をベンダー中立に保つ。** アプリコード（`opentelemetry-api`/`-sdk` への依存）は
  X-Ray 固有の型に触れない。エクスポート先を変える判断は将来コレクタの設定変更だけで完結
  し、計装のやり直しが要らない。
- **サイドカー自体は案 B と同じコストなので、「サイドカーを避ける」動機にならない。**
  Fargate では daemon/collector いずれの方式でも同一タスク内の追加コンテナが要る
  （awsvpc モードで localhost 到達）。ならばベンダー中立な OpenTelemetry を選ぶ方が良い。
- **`amazon/aws-otel-collector` の `AOT_CONFIG_CONTENT` 環境変数**でコレクタ設定
  （OTLP receiver → AWS X-Ray exporter のパイプライン）をインライン注入でき、専用の
  カスタムイメージビルドが不要（ECR リポジトリ追加やビルドパイプラインの複雑化を避けられる）。
- **却下案 B（`aws-xray-sdk` + X-Ray デーモン）:** 実現性・到達性は案 A と同等だが、
  アプリの計装コードが X-Ray 固有 API に直接依存する。将来の柔軟性で劣り、かつサイドカーを
  避けられる訳でもないため採らない。
- **却下案 C（サイドカー無しで直接 X-Ray/OTLP エンドポイントへ送信）:** X-Ray への直接
  OTLP 送信は SigV4 署名が必要で、標準の OpenTelemetry Python エクスポータは対応していない
  （自前実装が要り、保守負担とリスクが高い）。`aws-xray-sdk` もデーモンレスモードが無い。
  結局サイドカーが必要になる案 A/B に劣後するため採らない。

### 実装の要点

- **トレースID とログの相関**: 構造化ログ（#42、`api/logging_config.py`）の `JsonFormatter`
  に、現在の OpenTelemetry スパンがあれば `trace_id`/`span_id` を追加する。アプリ独自の
  `request_id`（`CorrelationIdMiddleware`）とは別軸の ID として両方を残す
  （`request_id` はクライアント指定を尊重できる値、`trace_id` は X-Ray コンソールへの
  ジャンプに使う値、と役割を分ける）。
- **VPC インターフェースエンドポイント追加**（`infra/endpoints.tf`）: `xray` を
  `local.interface_endpoints` に追加する。追加の月額固定費が発生する
  （既存の ECR/Logs/Secrets Manager と同水準、AZ 数分）。トレーシングは #42 の完了条件
  そのものなので、コスト最適化のためにトレーシングを無効化する選択は採らない
  （dev で無効化したい場合は `var.otel_traces_enabled` で切れるようにする）。
- **タスク定義のリソース増**: サイドカー分の CPU/メモリを確保するため
  `aws_ecs_task_definition.api` の task 全体の cpu/memory を引き上げる
  （256/512 → 512/1024）。

## Consequences

- **良い面:** 将来トレースバックエンドを変える判断（コスト・機能面で X-Ray から Grafana
  Tempo 等へ移る等）がアプリの再計装無しで行える。ログとトレースが `trace_id` で相互参照
  できる。
- **受け入れるコスト:**
  - VPC インターフェースエンドポイント追加分の月額固定費（既存 4 エンドポイントに 1 つ
    追加、AZ 数分のENI）。
  - ECS タスクの CPU/メモリ増（256/512 → 512/1024）による実行コスト増。
  - サイドカーコンテナの分だけ ECS タスクの起動・障害点が増える（コレクタが落ちても
    アプリ自体は継続稼働する設計 — OTLP エクスポータの送信失敗はアプリ内で握りつぶし、
    リクエスト処理をブロックしない）。
- **再検討トリガー:**
  - トレース量が増えてコレクタのリソースが不足したとき（サイドカーの cpu/memory 見直し、
    または専用サービスとしての分離）。
  - X-Ray 以外のトレースバックエンドが必要になったとき（コレクタのエクスポータ設定変更で
    対応、アプリ計装は変更不要という本 ADR の前提が効いてくる）。
  - NAT ゲートウェイを別の理由で導入した場合、`xray` インターフェースエンドポイントの
    要否を見直す（NAT 経由でも到達できるため）。
