# ADR-0023: CD系ワークフローの重複を reusable workflow / composite action へ集約する

- **Status:** Accepted
- **Date:** 2026-07-23
- **Deciders:** itouhi
- **Related:** [#617](https://github.com/iwata-jawsug-jp/devcon/issues/617)、
  [ADR-0012](0012-reusable-workflow-in-repo-tag-versioned.md)（CI 側の reusable workflow 化。
  本 ADR はその CD 版）、[ADR-0015](0015-live-smoke-reusable-workflow.md)（同じ手法を
  live-smoke ゲートに適用した先行事例）

## Context

`.github/workflows/` の全21ワークフローを比較した結果、CI系(`ci.yml`/`ci-sandbox.yml`)は
ADR-0012・ADR-0015に沿って`reusable-*.yml`へ共通化済みだが、**CD系**
(`cd-app.yml`/`cd-app-sandbox.yml`/`cd-app-verify.yml`/`cd-sandbox-cycle.yml`)は
「build → migrate → deploy(ECS) → frontend」というAWS CLIロジックが4ファイルにほぼ同一の
シェルスクリプトとして複製されていた。`cd-sandbox-cycle.yml`自身のコメント(実装時点)が
「本来ADR-0012/#295と同じreusable workflow化で解消すべき負債だが、ここでは対応していない」と
明記しており、この負債は発生時点で認識済みだった。

同様に、Terraformの`infra/env/*.backend.hcl`/`*.tfvars`を`.example`テンプレートから
`sed`で生成するロジックが、`cd-infra.yml`(単体で3回)/`cd-infra-sandbox.yml`/
`cd-infra-verify.yml`/`cd-sandbox-cycle.yml`に計9箇所、バイト単位で同一のまま重複していた。

いずれも実際にAWSへデプロイ・apply/destroyするコードパスであり、変更を誤ると本番/sandbox環境の
実害につながるため、「ロジック自体は動かさず箱を移すだけ」という制約のもとで設計した。

## Decision

### 1. tfvars/backend.hcl 生成を composite action へ集約

`.github/actions/materialize-tfvars`(composite action、入力`tf_env`/`state_bucket`/
`project_name`)へ、9箇所に重複していた2行の`sed`スクリプトをそのまま移設した。

- **composite actionは呼び出し元の`vars`コンテキストを直接参照できない**(実装中にPR #618の
  CIで`Unrecognized named-value: 'vars'`のTemplateValidationExceptionとして判明)。
  reusable workflow(`workflow_call`)とは異なり、composite actionの`action.yml`自身の式評価は
  呼び出し元のリポジトリコンテキストを継承しないため、`vars.AWS_TF_STATE_BUCKET`/
  `vars.PROJECT_NAME`は呼び出し元(各`cd-*.yml`)から明示的に`with:`のinputとして渡す設計に
  修正した。
- 併せて、`terraform_version: '1.13.0'`の全出現箇所に、`TFLINT_VERSION`/`TRIVY_VERSION`/
  `CONFTEST_VERSION`と同じ「`.devcontainer/Dockerfile`の`TERRAFORM_VERSION`と単一ソース、
  更新時は両方直すこと」というコメントを追加した(値は変更しない、既存の単一ソース運用が
  Terraform本体のバージョンにだけ適用されていなかった抜けを埋めた)。

### 2. build→migrate→deploy→frontend を `reusable-app-deploy.yml` へ集約

ADR-0015と同じ「mechanism は共有・policy は呼び出し側」の原則を踏襲し、
`.github/workflows/reusable-app-deploy.yml`(`workflow_call`)へ抽出する。ジョブ粒度は
`cd-app.yml`(本番相当・最も安全側)の形を正とする: `build` → `migrate` →
`deploy-api`(`needs: build`だが`if:`なし — buildがskipされれば自動カスケードでskip)、
`frontend`(独立)。

呼び出し元ごとの差異はすべて`workflow_call`の入力として表現し、隠れた動作変更を作らない:

- `desired_count`(string, default `''`): 空なら`--desired-count`を付けない。`cd-app.yml`は
  ECS自動スケールの値を尊重するため常に空。sandbox/verify/cycleは`'1'`を渡す。
- `environment`(string, default `''`): ADR-0015の`reusable-live-smoke.yml`と同じ慣習
  (OIDCの`sub`クレームに影響するため、実際に`configure-aws-credentials`を呼ぶジョブにだけ
  値を通す)。
- `should_run_backend`/`should_run_frontend`(boolean, default `true`): ADR-0012の教訓
  (呼び出しジョブに`if:`を付けず、`should_run`をinputで内側の`if:`に渡す)を踏襲。
- `role_arn`は入力に取らない — 4呼び出し元すべてが同一の`vars.AWS_DEPLOY_ROLE_ARN`を参照して
  おり(`cd-app-verify.yml`も現状すでにこの変数を直接参照している)、これは
  composite actionと異なり`workflow_call`側は`vars`コンテキストを直接参照できるため可能。

`cd-app.yml`/`cd-app-sandbox.yml`の`preflight`ジョブが持つ「リポジトリ変数が全部埋まっているか」
チェック(bashの間接参照`${!v}`が2箇所に複製)も、`.github/actions/check-app-vars`
(named inputで受け取る composite action)へ統合する。`cd-app-verify.yml`のsmoke-testも独自の
inline実装をやめ、`reusable-live-smoke.yml`呼び出しに統一する(ADR-0008が意図した「1箇所集約」に
4ワークフロー中3つしか揃っていなかった欠落を埋める)。

## Consequences

- **良い面:**
  - CD系4ファイル分のAWS CLIロジック重複が1箇所(`reusable-app-deploy.yml`)に集約され、
    ECSタスク定義登録・Alembicマイグレーション実行の手順を変える際は1箇所の変更で4ワークフローに
    反映される。ADR-0012/ADR-0015と同じ設計原則をCD系のapp-deployにも展開できた。
  - `cd-app-verify.yml`の`workflow_call.inputs`シグネチャは変えないため、呼び出し元
    `cd-infra-verify.yml`は無変更で済む。
  - tfvars生成の共通化により、`infra/env/*.example`のプレースホルダ規約
    (`REPLACE-ME-tfstate`/`devcon`)を変える際も1箇所の変更で済む。
- **トレードオフ・新たに生じる負担:**
  - composite actionは`vars`/`secrets`コンテキストを暗黙に継承しないため、呼び出し元が
    毎回明示的に`with:`で渡す必要がある(reusable workflowより冗長)。この制約は
    `materialize-tfvars`のREADME相当(action.yml自身のinput descriptionコメント)に明記した。
  - ジョブが1段階深くなる(`app-deploy / build`のように)。可読性はやや下がるが、
    ADR-0012/0015と同じ判断で、drift防止の利益の方が大きいと判断。
  - `.github/workflows/cd-*.yml`の変更のため、`docs/issues.md`の規律に従い
    sandbox実機検証(`cd-sandbox-cycle.yml`の`workflow_dispatch`実行)を経てから
    mainへマージする運用とした。
- **再検討トリガー:** 下流(公開ミラー`iwata-jawsug-jp/devcon`経由でのテンプレート配布)が
  `reusable-app-deploy.yml`/`materialize-tfvars`を参照したいニーズが出た場合、ADR-0012と
  同じタグ参照方式を適用する。
