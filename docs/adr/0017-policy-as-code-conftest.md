# ADR-0017: Terraform plan の組織固有ポリシー検証に conftest（OPA/Rego）を使う

- **Status:** Accepted
- **Date:** 2026-07-16
- **Deciders:** itouhi
- **Related:** #296, #285, #153, #279, [ADR-0009](0009-iam-access-analyzer-static-policy-validation.md)

## Context

既存のガードレール（tflint / checkov / trivy）は汎用ルールセットであり、「このリポジトリ固有の
規約」は検証できない。実例:

- #285: IAM ポリシーで `aws:RequestedRegion` 条件を付け忘れる、といった規約違反は tflint の
  AWS ルールセットにも checkov の既定ポリシー集にも存在しない
- #153 のレビュー指摘の多く（タグ規約、命名規約、ワイルドカード許可の禁止）も同様に、
  汎用スキャナの対象外

AI エージェントがコードを書く比率が上がるほど、この種の「組織固有の暗黙知」を人間のレビューだけに
頼るのはスケールしない。`terraform show -json` の plan JSON に対して機械検証する層を追加し、
レビューの人間依存を減らす。

### 配線コストの調査結果

issue 起票時点では「新規ツールチェーン導入＋ plan JSON 化パイプラインの新規構築」が両方必要と
見積もっていたが、実際に調べると:

- **`cd-infra.yml` の `plan` ジョブは既に `terraform show -json tfplan` を生成済み**
  （[ADR-0009](0009-iam-access-analyzer-static-policy-validation.md) の accessanalyzer 検証が
  同じ JSON を使っている）。conftest はこの既存の JSON にもう1ステップ足すだけで済み、
  新規の JSON 化配線は不要。
- `ci.yml` の `infra` ジョブ（`terraform validate`/tflint/checkov/trivy）は AWS 認証なしで
  動く設計（`init -backend=false`）のため、実際の `terraform plan` を生成できない。したがって
  conftest による plan JSON 検証は **`cd-infra.yml` の `plan` ジョブでのみ**成立する
  （ADR-0009 と同じ構造上の制約）。

## Decision

**[conftest](https://www.conftest.dev/)（OPA/Rego）を採用し、`cd-infra.yml` の `plan` ジョブに
組み込む。**

### ツール選定

- **conftest を採用。** OPA を直接使う場合と機能的な差はほぼ無いが、conftest は
  `terraform show -json` のような構造化データに対する CLI ラッパーとして開発されており、
  `conftest test` / `conftest verify`（Rego のユニットテスト）のコマンド体系がこのユースケースに
  そのまま合う。
- **Sentinel は不採用。** HashiCorp Cloud/Enterprise 前提の商用機能で、OSS の Terraform CLI
  運用（本リポジトリの構成）とは前提が合わない。
- **既存の accessanalyzer 検証（ADR-0009）は統合しない。** 対象とする不正のクラスが異なる:
  accessanalyzer は「実在しない条件キー」のような**AWS 側のポリシー文法**を実際の API 呼び出しで
  検証するのに対し、conftest/Rego は「タグを付けろ」「ワイルドカードアクションを禁止する」
  といった**このリポジトリ固有の規約**をオフラインで検証する。ADR-0009 の却下案セクションで
  「#296 導入後に再検討する」としていた論点だが、性質が違うため両者を並行運用する。

### パイプライン設計

- `cd-infra.yml` の `plan` ジョブで `terraform show -json tfplan > plan.json`
  ステップを共通化し（従来は accessanalyzer 検証だけのために `iam-plan.json` という名前で
  生成していた）、accessanalyzer 検証と conftest の両方に同じ JSON ファイルを渡す。
- ポリシーは `infra/policy/*.rego` に配置。全ポリシーは `package main` を共有し、`deny` ルールを
  ファイルごとに追加していく（conftest の一般的な構成 — 1ファイル1関心事、`conftest test` 実行時は
  全ファイルの `deny` が論理和で評価される）。
- 各ポリシーに対応する `*_test.rego`（`conftest verify` で実行する Rego ユニットテスト）を必須とし、
  実際の AWS 環境や `terraform plan` なしでロジックを検証できるようにする。
  **注意（テストを書く際の罠）:** `package main` を共有するため、あるテストファイル内の
  `deny with input as {...}` は**そのファイルのルールだけでなく、他の全ファイルの `deny` ルールも
  含めた論理和**を評価する。無関係な規約（例: タグ）を偶然トリガーしないよう、テスト用の入力は
  「今検証したい観点以外は全て正常な状態」にすること（各テストファイルにコメントで明記）。

### Blocking か Warning か（Count → Block 段階導入との比較）

WAF（#279）は実トラフィックに対するルールのため、誤検知で正規リクエストを止めるリスクがあり
Count→Block の段階導入が妥当だった。conftest は**宣言的な IaC の構成**に対する決定的な検査であり、
実行するたびに同じ入力に対して同じ結果を返す（本番トラフィックのような非決定性がない）。
誤検知が疑われる場合は PR レビューの中でポリシー自体を直せばよく、ロールアウト中の観測期間を
設ける必要性が薄い。**したがって初期ポリシーから blocking（`conftest test` の非ゼロ終了で
CI を fail させる）とする。**

### 初期ポリシー（本 PR のスコープ）

現在の app 層（`infra/*.tf`）の構成に対して**現状パスする**ものを選び、パイプライン自体の
正しさを実証しつつ将来の回帰を防ぐガードとする:

1. **`tags.rego`** — `tags_all` を持つ全リソースに `Project` / `Environment` タグが存在すること。
   `default_tags`（`providers.tf`）が既に全リソースへ自動付与しているため、現状は常にパスする
   はずのリグレッションガード。
2. **`iam_wildcard.rego`** — 識別ポリシー（`aws_iam_policy` / `aws_iam_role_policy` /
   `aws_iam_user_policy`）の `Allow` ステートメントでワイルドカードアクション
   （`"*"` または `"service:*"` 形）を禁止。`Deny` ステートメントのワイルドカードは
   ガードレールとして意図的なものなので対象外。

### 見送った初期候補（follow-up として #296 に残す）

- **S3 バケット暗号化/パブリックアクセスブロック必須** — 現状の `web.tf` の S3 バケットは
  サーバサイド暗号化設定を持たない（#280 の指摘と同一）。ここで検証を追加すると即座に fail する
  ため、暗号化の実装（#280 のスコープ）と一緒でないと導入できない。conftest 導入自体の
  スコープと混ぜず、#280 側で対応する。
  - **教訓:** 「まだ実装されていない規約」を conftest ポリシーとして先に追加すると、
    その場で CI が壊れる。ポリシー追加は「現状の構成に対する回帰防止」から始め、
    「あるべき姿への強制」は対象の実装と同じ PR/issue で行う。
- **`aws:RequestedRegion` 条件チェック（#285 再発防止）** — この条件が必要なのは主に
  `infra/bootstrap/` の IAM ポリシー（CI 外・ローカル apply 運用、ADR-0009 と同じ制約）。
  app 層（`shared.tf` の `ecs_execution_secret`）には現状この条件がなく、追加するなら
  ポリシー導入とセットで実際の `.tf` 変更が必要になるため、#280/#281 系の作業と合わせて
  別 PR で検討する。
- **#364 由来の3候補**（VPC エンドポイント到達性、デプロイ workflow の env var 注入チェック、
  CSP `connect-src` チェック）— いずれも `terraform show -json` 単体では検証しきれない
  （GitHub Actions workflow YAML が対象だったり、外部依存の静的解析が必要だったりする）。
  conftest の対象範囲を超えるため、別途の実装方式検討を要する follow-up とする。

### 3層配線

`.devcontainer/Dockerfile`（`CONFTEST_VERSION` pin）→ pre-commit（`conftest verify` を
`infra/policy/**` 変更時のみ実行 — ローカルには実 AWS 認証情報がなく `conftest test` は
実行できないため、ユニットテストのみをローカル/pre-commit のゲートにする）→ Makefile
（`make policy-test` が `conftest verify` を実行、`make lint` に組み込み）→ CI。CI 側は
2ジョブに分かれる: `ci.yml`（`reusable-infra.yml`、AWS 認証不要）は `conftest verify`
のみを実行し `make lint` / pre-commit と揃える。`cd-infra.yml` の `plan` ジョブ（AWS
plan ロールで実際に `terraform plan` する）は `conftest verify` に加えて実際の plan JSON
に対する `conftest test` を実行する。

## Consequences

- **良い面:** タグ規約・IAM ワイルドカード規約が PR ごとに機械検証され、レビュー漏れに依存しなく
  なる。将来のポリシー追加は `infra/policy/*.rego` + `*_test.rego` を足すだけで、
  ワークフロー変更が不要。
- **受け入れるコスト:**
  - 新規ツールチェーン（conftest/OPA/Rego）が devcontainer / pre-commit / Makefile / CI の
    4箇所に増える。
  - `package main` 共有によるテスト間の意図しない干渉に注意が必要（上記の罠を参照）。
  - 初期ポリシーは意図的に「今パスするもの」に絞ったため、#296 が扱おうとしていた規約の
    大部分（S3 暗号化、region 条件、#364 由来の3件）はまだ未実装のまま残る。
- **再検討トリガー:**
  - #280（KMS CMK / S3 暗号化）が完了したら、S3 暗号化ポリシーを conftest 側にも追加する
    （実装と検証を対にする）。
  - `infra/bootstrap/` を CI 化する判断がされた場合、region 条件チェックをそちらにも
    展開できるか検討する。
  - Rego ポリシーが増えて `package main` の共有が見通しを悪くしてきたら、
    サブパッケージ分割 + `conftest test --all-namespaces` への切り替えを検討する。
