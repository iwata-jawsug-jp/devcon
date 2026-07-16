# ADR-0009: IAM 識別/許可ポリシーの静的検証に AWS IAM Access Analyzer の `validate-policy` を使う

- **Status:** Accepted
- **Date:** 2026-07-13
- **Deciders:** itouhi
- **Related:** #340, #338, #296, #285

## Context

#338 で、`ci_deploy` ポリシーの `EcsTaskDefinitions` ステートメントが**実在しない条件キー**
（`ecs:task-definition-family`）により無言で無効化されていたことが判明した。この種のバグは
`terraform validate` / tflint（AWS ルールセット）/ Checkov の**全ゲートを素通りする**（HCL・
レンダリング後の JSON ともに文法的には正しいため）。発見は sandbox 実機の `AccessDenied`
ループ頼みになり、#326〜#339 で実際に多数の PR サイクルを要した。

`aws accessanalyzer validate-policy` がまさにこのクラスを ERROR
（`INVALID_SERVICE_CONDITION_KEY`）で検出することをライブテストで確認済み。オフライン代替の
[parliament](https://github.com/duo-labs/parliament) も検討したが、SAR（Service Access
Reference）データの鮮度に不安があり、かつ後述の通り認証コストが実質ゼロだったため採用しなかった。

### 配線コストの当初の懸念と、実際の調査結果

issue 起票時点では「`ci.yml` の infra ジョブ（terraform validate/tflint/checkov/trivy 用）は
AWS 認証情報を持たない」ことが最大の懸念だった。実際にコードを確認した結果:

- **`cd-infra.yml` の `plan` ジョブ（PR 時に毎回走る）は既に OIDC 認証済み**（read-only PLAN
  ロール）で、既に `terraform plan -out=tfplan` を実行している。統合先をここにすれば、app 層
  （`infra/*.tf`）については新規の OIDC ロール追加は不要。
- `infra/bootstrap/` は CI 外・ローカル apply 運用（`docs/infrastructure.md`）のため、そちらは
  そもそも CI ジョブが存在しない。ローカルで既に AWS 認証済みの状態で apply する運用と整合する
  形（`terraform show -json terraform.tfstate` を `check_iam_policies.py` に渡すコマンド）に
  する。

## Decision

**`aws accessanalyzer validate-policy`（`--policy-type IDENTITY_POLICY`）で、`terraform show
-json` の plan/state から抽出した `aws_iam_policy` / `aws_iam_role_policy` /
`aws_iam_user_policy` の実データ（`.github/scripts/check_iam_policies.py`）を検証する。**

- **スコープを識別/許可ポリシーに限定する。** 信頼ポリシー（`aws_iam_role` の
  `assume_role_policy`）や リソースポリシー（S3 バケットポリシー等）は Access Analyzer では
  別の `--policy-type`（`RESOURCE_POLICY` 等）で検証形が異なるため、今回は対象外とする
  （#338 の実際のバグも識別ポリシー側で発生している）。広げる場合は別途の follow-up とする。
- **2 層構成で配線する**（#285 で明文化した bootstrap の CI 外運用と同じ考え方）:
  - **app 層**: `cd-infra.yml` の `plan` ジョブに組み込み、PR ごとに自動検証（対象は現状
    `aws_iam_role_policy.ecs_execution_secret` の 1 件のみ、`shared.tf`）。
  - **bootstrap 層**: `terraform show -json terraform.tfstate` の出力を
    `check_iam_policies.py` に渡すローカル専用コマンド（要 AWS 認証）。対象は
    `ci_deploy_*` / `tfstate_access_*` の 9 件（実際に #338 が発生した層）。CI ジョブを持たない
    ため、bootstrap を変更したら手動で実行することを運用として求める。
- **PR-plan ロールに `access-analyzer:ValidatePolicy` を明示的に付与する**
  （`infra/bootstrap/main.tf`）。この呼び出しは特定のリソース ARN を持たず
  （ポリシー文書自体をリクエスト引数として渡す）読み取り専用・副作用なしのため
  `Resource "*"`。`ReadOnlyAccess`（AWS 管理ポリシー）が暗黙にカバーしている可能性はあるが、
  それに賭けず明示的に付与する（#45 の最小権限方針: 広い AWS 管理ポリシーの未文書化された
  カバレッジに依存しない）。

### 却下案

- **parliament（オフライン）**: 認証不要な利点はあるが、SAR データの鮮度に依存し、かつ
  accessanalyzer の認証コストが上記の通り実質ゼロだったため、優位性が無い。
- **conftest/OPA（#296 の対象範囲）**: 汎用的な Policy as Code 基盤としては別 issue（#296）の
  スコープ。本 ADR は #338 の再発防止という狭い・具体的な目的に対して、汎用フレームワーク導入
  無しで対応できる最小手段を選んだ。#296 が導入された後、本チェックをその基盤上へ統合し直すか
  どうかは #296 側で再検討する。

## Consequences

- **良い面:** #338 と同クラスのバグ（実在しない条件キーによる無言のステートメント無効化）が
  sandbox 実機の `AccessDenied` を待たずに検出できる。新規ツールのインストール・バージョン
  ピン留めが不要（`aws` CLI は devcontainer/CI ランナーに既に存在）。
- **受け入れるコスト:**
  - `cd-infra.yml` の `plan` ジョブに Python セットアップ + 1 ステップ追加（実行時間への影響は
    軽微、`accessanalyzer:ValidatePolicy` はポリシー1件あたり高々数百ms程度の呼び出し）。
  - bootstrap 層の 9 ポリシーは CI では検証されず、ローカル実行（`terraform show -json
terraform.tfstate` → `check_iam_policies.py`）を忘れると見逃される。忘れないための
    機械的な強制（pre-commit 等）は、bootstrap が CI 外でローカル AWS 認証を前提とする構造上、
    現状は導入していない。
- **再検討トリガー:**
  - #296（Policy as Code / conftest）が導入された場合、本チェックをそちらへ統合するか、
    独立のまま維持するかを判断する。
  - 信頼ポリシー・リソースポリシーへのスコープ拡張が必要になった場合（別 `--policy-type` での
    検証追加）。
  - bootstrap 層の検証忘れが実際に問題になった場合、CI 外でも機械的に強制する手段
    （例: bootstrap 変更を検知して issue にチェックリストを自動追記する等）を検討する。
