# 変更履歴

このプロジェクトのすべての重要な変更をこのファイルに記録します。

書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に準拠し、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従います。

## [Unreleased]

## [0.6.7] - 2026-07-23

### Changed

- **CD系ワークフローの重複ロジックを reusable workflow / composite action へ集約（[ADR-0023](docs/adr/0023-cd-app-deploy-reusable-workflow-and-tfvars-materialize.md)）**: CI系（`ci.yml`/`ci-sandbox.yml`）はADR-0012/ADR-0015で既に共通化済みだったが、CD系（`cd-app.yml`/`cd-app-sandbox.yml`/`cd-app-verify.yml`/`cd-sandbox-cycle.yml`）は「build→migrate→deploy(ECS)→frontend」のAWS CLIロジックが4ファイルにほぼ同一のシェルスクリプトとして複製されており、`cd-sandbox-cycle.yml`自身のコメントが「本来reusable workflow化で解消すべき負債」と自認していた。`.github/workflows/reusable-app-deploy.yml`へ抽出し、`desired_count`/`environment`/`should_run_backend`/`should_run_frontend`をworkflow_call inputで表現することで、本番はECS自動スケール値を尊重してdesired_count省略・sandbox系は固定値`'1'`といった呼び出し元ごとの既存差異を隠れた動作変更なしに再現した。あわせて`.github/actions/check-app-vars`でpreflightの変数存在チェックを、`.github/actions/materialize-tfvars`でTerraformのtfvars/backend.hcl生成（`cd-infra.yml`/`cd-infra-sandbox.yml`/`cd-infra-verify.yml`/`cd-sandbox-cycle.yml`に計9箇所重複）を統合し、`cd-app-verify.yml`のsmoke-testも独自inline実装をやめ`reusable-live-smoke.yml`呼び出しに統一した（ADR-0008の「1箇所集約」の欠落を解消）。両フェーズともsandbox実機検証（apply→deploy→live-smoke→teardown）完走を確認済み（#617）。

### Fixed

- **`docs/sandbox.md`にworkflow_dispatch実行時のOIDC ref制約を明文化**: `cd-sandbox-cycle.yml`/`cd-infra-sandbox.yml`/`cd-app-sandbox.yml`が assume する deploy role の OIDC 信頼ポリシーは`ref:refs/heads/main`/`ref:refs/heads/sandbox/*`からしか許可しないため、それ以外のブランチを`workflow_dispatch`の`--ref`に指定すると`AssumeRoleWithWebIdentity`が確実に失敗する（2026-07-19の実行、2026-07-23の実行で再現）。コードのバグと誤解しやすいため、原因と対処（検証用`sandbox/*`ブランチを作ってそちらを`--ref`に指定する）を明記した（#617）。

## [0.6.6] - 2026-07-21

### Added

- **CD App用リポジトリ変数を terraform output から自動登録する `tools/script/write-cd-app-vars.sh` を追加**: `infra/`（アプリ層）を dev/prod/sandbox 向けに apply した後、`cd-app.yml`/`cd-app-sandbox.yml` が必要とする12個のリポジトリ変数を、これまで手動で `gh variable set` を12回打っていたのを自動化した（`bootstrap.sh write` と同じ発想）。`prod` は接頭辞なし、`sandbox` は `SANDBOX_` 接頭辞、`dev` は `DEV_` 接頭辞（現時点で消費する workflow は無いが、将来の `cd-app-dev.yml` に備えた予定枠）で登録する。`docs/repository-variables.md` に新カテゴリ「5. dev用」を追加し、`check-repo-vars.sh` もこれに追従させた（#615）。
- **`bootstrap.sh write` でリポジトリ変数の書き込みに `GH_CHECK_SETUP_TOKEN` を使えるようにした（[ADR-0022](docs/adr/0022-widen-check-setup-token-scope-for-bootstrap-write.md)）**: GitHub Codespaces の既定認証（Codespaces注入の `GITHUB_TOKEN`）は Actions Variables への書き込み権限を持たないことがあり、これまで `write` 実行のたびに `GH_TOKEN=<token>` を都度指定する必要があった。`GH_CHECK_SETUP_TOKEN` のスコープを Read-only から Read and write へ拡張する方針とし（ADR-0021 を Superseded）、`resolve_published_values`（`recover`/`adopt`）と同じトークン発見ロジックを `cmd_write` でも使うようにした（#612）。

### Changed

- **AWS 一時クレデンシャル発行手順の第1優先を `aws login` に変更**: `docs/aws-temporary-credentials.md` に「## 1. `aws login`（推奨）」を新設した。AWS CLI 2.32以降が提供する `aws login` は既存のコンソールサインイン（root/IAMユーザー/フェデレーテッドID）をそのまま使い、長期アクセスキーを一切作らずに一時クレデンシャルを発行できるため、これまでの推奨手順だった IAM ユーザー + `get-session-token` 等より前提条件が軽い。既存4手法は「`aws login` が使えない場合の代替」として2〜5に繰り下げ、devcontainer/Codespacesでブラウザが開けない場合の `--remote` オプション等も手順化した（#613）。

### Fixed

- **`bootstrap.sh` の `resolve_published_values`（`recover`/`adopt` が使う読み取り経路）で、権限不足時に `set -e` が誤って即終了しmissingチェックのエラーメッセージが一切表示されない不具合を修正**: `[[ -z "$x" ]] && x="$(gh_var ...)"` という書き方だと代入コマンドが `&&` リストの最後になり、`gh variable get` が403等で失敗すると即座にスクリプトが終了していた。各行を独立した `if` 文にし、失敗を `|| true` で吸収して後段のmissingチェックへ委ねるよう修正した（#611）。

### Security

- **frontend の Dependabot アラート対応（[iwata-jawsug-jp/devcon#4](https://github.com/iwata-jawsug-jp/devcon/security/dependabot/4)）**: `js-yaml` がマージキー（`<<`）を連鎖させたYAMLでO(N²)のCPU時間を消費するDoSを4.3.0で修正しているが、`package-lock.json` では2箇所（`@redocly/openapi-core` が固定する `4.2.0`、`@lhci/utils` が要求する `^3.13.1` の範囲）ともパッチ済みバージョンを含んでいなかった。`package.json` の `overrides`（`tmp`/`uuid` と同じ既存パターン）に `js-yaml@^4.3.0` を追加して強制固定した。`@lhci/utils` はjs-yaml 3.x系のみのAPI（`safeLoad`）を使うが、呼び出し箇所は `.lighthouserc.yaml`/`.yml` を読む分岐のみで、このリポジトリの設定は `lighthouserc.json`（JSON分岐）のため実行時には影響しない。lint/typecheck/test/build/`npm audit` で動作確認済み（#614）。

## [0.6.5] - 2026-07-20

### Changed

- **`cd-infra.yml` の `apply` で dev/prod を選択できるようにした（デフォルト `dev`）**: 従来 `apply` は prod 固定だった。`workflow_dispatch` に `environment` 入力（choice: `dev`/`prod`、デフォルト `dev`）を追加し、`apply-dev`/`apply-prod` の2ジョブに分割した。1ジョブで `environment:` を動的に切り替える案は、`environment:` を宣言するとOIDCトークンの`sub`クレームが`repo:<org>/<repo>:environment:<name>`になり、`infra/bootstrap`のdeploy-role trust policyが`environment:production`しか許可していないため未知の環境名だと認証が壊れるという#392/#393と同型のOIDCの罠（`cd-infra-verify.yml`が同じ罠を回避した設計と同じ考え方）を踏むため採用せず、`apply-dev`は`environment:`を宣言しない（`ref:refs/heads/main`のtrustに乗る）、`apply-prod`のみ従来通り`environment: production`を維持する設計にした（#609）。

## [0.6.4] - 2026-07-20

### Added

- **リポジトリ変数一覧 `docs/repository-variables.md` を新設し、CI/CD が参照する全33変数（bootstrap配線4/エリアスイッチ5/本番アプリ用12/sandbox用12）を横断できる表に集約**: 従来 `docs/ci-cd-area-switches.md`/`docs/infrastructure.md`/`docs/sandbox.md`/`docs/scaffold-cli.md` の4ドキュメントに分散し全体を一望できなかった（動線の悪さがユーザーから指摘され対応）。既存ドキュメントの重複列挙は新ドキュメントへのリンクに統一した。あわせて `tools/script/check-repo-vars.sh`（`make check-repo-vars`）を新設し、workflow参照・ドキュメント記載・実際の登録状況（`gh variable list`）の3者を突き合わせてドリフト（ドキュメント漏れ・廃止済み記載・登録忘れ・orphan登録）を検出できるようにした。本番/sandbox用変数は全部登録or全部未登録を正常とみなし中途半端な登録数のときだけ警告する設計とし、本番インフラ未構築による恒常的な誤警告を回避した。`check-devenv-setup.sh` のbootstrap配線チェックに漏れていた `PROJECT_NAME` も追加した（docs/proposal/repository-variables-navigation-proposal.md, #606）。
- **[ADR-0021](docs/adr/0021-codespaces-user-secrets-for-check-setup-token.md) を追加し、`check-devenv-setup.sh`/`check-repo-vars.sh` が GitHub Codespaces のユーザーシークレットから `GH_CHECK_SETUP_TOKEN` を自動取得できるようにした**: 確認専用トークンを git-ignored の `.env.check-setup` に手動保存する従来運用は、Codespace を作り直すたびに再作成が必要で、`check-repo-vars.sh` の追加（#606）で同じ手間が2倍になっていた。環境変数 `GH_CHECK_SETUP_TOKEN` が既にセットされていれば（`github.com/settings/codespaces` のユーザー個人シークレットからの自動注入を想定）優先し、`.env.check-setup` は非Codespaces向けフォールバックにした。`CODESPACES` 環境変数の有無で案内メッセージも出し分ける（#607）。

### Fixed

- **`infra/bootstrap/main.tf`（#585で用途別ファイルへ分割済み）への古い参照をドキュメント4ファイル計18箇所で修正**: `docs/infrastructure.md`・`infra/bootstrap/README.md`・`docs/sandbox.md`・`docs/scaffold-cli.md` が、v0.6.1（#585）で存在しなくなった `infra/bootstrap/main.tf` を実在するかのように参照し続けていた。`bootstrap.sh destroy` が同種の参照ドリフトで実際に壊れていた #599（PR #601）と同じパターンがドキュメント側にも広範囲に残っていたことをリリース後の整合性確認で発見し、実際の配置先（`locals.tf`/`iam-ci-roles.tf`/`oidc.tf`/各 `iam-ci-deploy-*.tf`）または汎用表現へ書き換えた（#604, #605）。

## [0.6.3] - 2026-07-20

### Fixed

- **bootstrap ci-deployロールに `sns:GetSubscriptionAttributes`/`sns:SetSubscriptionAttributes` 権限を追加**: 外部の実機検証リポジトリ（`itouhi/devcon`、本テンプレートから生成したプロジェクトでの運用検証用）で、`alert_email` 設定済みのprod環境の `cd-infra.yml` apply が、Terraformプロバイダーがサブスクリプション作成直後に行う属性読み戻し（`GetSubscriptionAttributes`）で403となり失敗する事象が発見・修正された（[itouhi/devcon#1](https://github.com/itouhi/devcon/issues/1)）。本リポジトリ（テンプレート本体）の `infra/bootstrap/iam-ci-deploy-observability.tf` にも同じ権限漏れが存在したため反映し、実AWS環境（`terraform apply`）への適用まで確認した（#597）。
- **`bootstrap.sh destroy --include-state-bucket` が存在しない `infra/bootstrap/main.tf` を参照し失敗する不具合を修正**: `infra/bootstrap/` は `main.tf` から用途別ファイル（`state.tf`/`iam-*.tf`/`oidc.tf` 等）へ既に分割済みだが、`cmd_destroy` が分割前の名残で `main.tf` を `cp`/`sed` しようとして `No such file or directory` で落ち、state バケットを削除できなくなっていた（`itouhi/devcon`での実機検証で発見・修正: [itouhi/devcon#9](https://github.com/itouhi/devcon/issues/9)）。`prevent_destroy = true` の実体がある `state.tf` を参照するよう修正した（#599）。
- **ADOTコレクタのイメージ（`public.ecr.aws`）がNAT無しVPCから到達不能で本番apiがダウンしうる不具合を修正**: `otel_traces_enabled = true`（`infra/env/prod.tfvars.example` のデフォルト）の環境で、ADOTコレクタサイドカーのイメージpullがNAT無しVPCから失敗し `CannotPullContainerError` でECSサービス全体がダウンする障害が、`itouhi/devcon` での実機検証で実際に発生した（[itouhi/devcon#3](https://github.com/itouhi/devcon/issues/3)）。同じ設計上のギャップが本リポジトリにも存在していたため、ECR pull-through cache（`aws_ecr_pull_through_cache_rule`）経由の取得に切り替え、付随して必要な `ecs_execution` ロール・bootstrap `ci-deploy` ロールの権限も同一PRで追加した（先に一方だけapplyして途中停止する事故を防ぐ、[itouhi/devcon#5](https://github.com/itouhi/devcon/issues/5)の教訓）。`sandbox/main` で実AWS apply→deploy→smoke-testまで検証し、`adot-collector` コンテナが`RUNNING`・pull-through cache経由の宛先ECRリポジトリが実際に作成されることを確認した（#598）。

## [0.6.2] - 2026-07-19

### Added

- **S3バケットの暗号化/パブリックアクセスブロック必須ポリシーをconftestに追加**: #296（Policy as Code導入）が当初見送っていた初期候補で、ADR-0017の再検討トリガー「#280（KMS CMK / S3暗号化）が完了したら追加する」に対応した。`infra/policy/s3_security.rego` を新設し、全 `aws_s3_bucket` に対応する `aws_s3_bucket_server_side_encryption_configuration` / `aws_s3_bucket_public_access_block`（4項目すべて `true`）の存在を、`bucket` 属性値（同一plan内での新規作成時はapply後まで未定）ではなくリソース命名規約（保護対象と同じローカル名を使う慣例）で突き合わせて検証する。`package main` 共有により既存の `tags_test.rego`/`iam_wildcard_test.rego`/`csp_test.rego` の無関係フィクスチャが新ポリシーを誤爆した（ADR-0017記載の既知の罠）ため、`aws_cloudwatch_log_group.app` に差し替えて解消した（#296 PR3, #593）。
- **[ADR-0019](docs/adr/0019-policy-as-code-downstream-distribution.md) を追加**: `infra/policy/*.rego` 専用の下流配布・追従機構は新設せず、初回配布は `copier copy`、実行エンジンの追従はreusable workflowのタグ参照（#295, ADR-0012）、ポリシー本文の更新追従は #298（テンプレート更新の下流追従）の既存スコープに委ねる設計を記録した。副次的に、`infra/policy/` が空/不在だと `reusable-infra.yml` の `conftest verify` が `no policies found` でCI失敗する（Policy as Codeをオプトアウトしたい下流リポジトリが踏むトラップ）ことをローカル再現確認し、#298側のfollow-upとして記録した（#594）。
- **[ADR-0020](docs/adr/0020-vpc-endpoint-reachability-detection-deferred.md) を追加**: 「VPCエンドポイント到達性の完全自動検出」（#296残スコープ最後の1件）の実装方式を検討した。調査の結果 `services/backend/python` にはAWS SDK呼び出しが現状ゼロ件（Cognito JWKSはHTTPS直叩き、RDSはVPC内直接TCP接続でエンドポイント概念自体が不要）と判明し、検出対象が存在しないため実装を見送った。実装方式（静的抽出スクリプト→`plan.json`へのマージ→相関Regoルール、補完策としてのOTel botocore instrumentation）は設計として確定させ、再検討トリガーを「backendに最初のboto3呼び出しが追加されるPR」とした。以上3件の完了・設計確定により #296 をクローズした（#595）。

### Fixed

- **`infra/web.tf` のS3バケット(web)にSSE-KMS（AWS管理キー `alias/aws/s3`）を設定したところ、CloudFrontが全リクエストで403 AccessDeniedを返しSPAが一切読み込めなくなる不具合を修正**: checkov `CKV_AWS_145`（S3はKMSで暗号化すべき）の継続的な検出に対応するため #590（#587）でSSE-KMS化したが、CloudFrontのOrigin Access Control（OAC）はSSE-KMS暗号化されたオブジェクトをカスタマー管理キー（CMK）でしか復号できず、AWS管理キーでは復号できない制約があり、週次のfrom-scratch applyサイクル（`cd-sandbox-cycle.yml`）のlive-smokeで403検出・原因特定した（#591）。#280（CMK導入見送り）の判断は維持しつつSSE-S3（`AES256`）へ戻し、checkovの当該指摘は3層すべてでsoft-fail済み（#111）の既存許容方針の範囲内として受け入れることにした。`sandbox/591-web-sse-s3` で `cd-sandbox-cycle.yml` を再実行し、live-smoke `1 passed` を確認したうえで修正した（#592）。

## [0.6.1] - 2026-07-19

### Added


### Changed

- **`infra/bootstrap/main.tf`（1378行の単一ファイル）をドメイン別に11ファイルへ分割**: app infra側（`api.tf`/`web.tf`/`network.tf`/`db.tf`/`auth.tf`/`observability.tf`）と対称的な構成にし、共有 `locals`（`name_prefix`/`repo`/`plan_subjects`/`deploy_subjects`/`region_condition`）は `locals.tf` へ集約した。リソースの追加・削除・変更は無く、`terraform plan` でゼロ差分を確認済み（#585、closes #584）。

### Fixed

- **`CHANGELOG.md` 末尾の compare リンク定義が v0.3.3 で更新が止まっており、`[0.3.4]`〜`[0.6.0]`（17リリース分）の見出しがリンクになっていなかった不具合を修正**: リリース手順書（`docs/release.md`）に footer 更新を明記し再発を防止した（#588）。
- **`infra/bootstrap` の CI ロール（`ci_plan`/`ci_deploy`）の OIDC 信頼ポリシーが、GitHub Actions が発行する `sub` クレームのフォーマット差異でリポジトリによって認証拒否される不具合を修正**: classic 形式（`repo:<org>/<repo>:...`）限定の `StringLike` 条件だったため、owner_id/repository_id 埋め込み形式の `sub` を発行するリポジトリで `AssumeRoleWithWebIdentity` が拒否され続けていた（#581）。`sub` のパターンマッチを撤廃し `repository`/`event_name`/`ref`/`environment` クレームの直接参照へ置き換える設計を試みたが、実 AWS 環境での実機検証でこれらのクレームが値の完全一致にもかかわらず認証を通さないことが判明し（AWS IAM がこの OIDC プロバイダーでは `sub`/`aud`/`job_workflow_ref` 以外を条件キーとして認識していないと推測）、最終的に `sub` ベースの設計へ戻し、各 subject を classic 形式・owner_id/repository_id 埋め込み形式の両方で列挙する方式に変更した（#582）。
- **tflint を v0.64.0 へ更新し、GitHub Attestation API の破壊的変更に対する暫定回避（legacy PGP 署名検証へのフォールバック、v0.3.13 で適用）を解除**: 2026-07-16 の GitHub Attestations API から `bundle` フィールドが削除された影響で v0.63.1 の tflint AWS プラグインが nil pointer panic していた問題（#510）が、上流の v0.64.0（2026-07-17リリース）で根本修正されたため、CI/devcontainer 双方のバージョンを更新し `.tflint.hcl` の暫定回避を撤去した（#586）。

## [0.6.0] - 2026-07-19

### Added

- **AWS MCP Server（Agent Toolkit for AWS）を `.mcp.json` に導入**: `docs/proposal/mcp-server-selection-proposal.md`（#566）の設計に基づき、AWS 公式 MCP Server を SigV4 方式（[`mcp-proxy-for-aws`](https://github.com/aws/mcp-proxy-for-aws) 経由）で追加した。提案書が示していた `"url"` 直接登録は OAuth 認証方式であり、ブラウザでサインインした人間自身の権限で実行されるため下記のエージェント専用 IAM ロールを一切経由しないことが判明し、SigV4 方式に訂正した。`.mcp.json` は `uvx` 経由で `mcp-proxy-for-aws==1.6.3`（`--profile agent-mcp` / `AWS_REGION=ap-northeast-1` / `--read-only`）を起動する。`.claude/settings.json` の `ask`（`Bash(aws:*)`）が MCP 経由の呼び出しには適用されない非対称性（実績: Terraform MCP のツール呼び出しが確認プロンプト無しで動作）を `docs/development-environment.md` に明記した（#572）。
- **AWS MCP Server 用エージェント専用 IAM ロールを新設**: `infra/bootstrap` に `ReadOnlyAccess` + 3つの Deny statement（MCP 経由以外を全拒否・`sts:AssumeRole` 拒否・破壊的操作の保険）で構成する `agent-mcp` ロールを追加し、CI の `ci_plan`/`ci_deploy` ロールとは信頼ポリシー・認証情報の発行経路を分離した。実 AWS への `terraform apply` 検証で2件のバグを発見・修正した: (1) `DenyDestructiveActions` の `"*:Delete*"`/`"*:Terminate*"` が IAM の「サービスプレフィックスにワイルドカード不可」制約に反し `MalformedPolicyDocument` で失敗する不具合、(2) ローカル state 消失後に `init` をやり直すと AWS 側に残った同名ポリシーと `EntityAlreadyExists` で衝突する不具合（`resource_name_suffix` 変数を追加し、bootstrap 管理の全 IAM ロール/ポリシー名にランダムサフィックスを付与して解消、`ci_plan`/`ci_deploy` 系も含めて命名規則を統一）。`bootstrap.sh` の `recover`/`adopt`/`destroy` が参照するリソース一覧にも新ロールを追加した（#571）。
- **`aws-sso-setup.sh` に `agent-mcp` プロファイル自動セットアップを追加**: `agent-mcp` サブコマンドが、指定 SSO プロファイルの認証状態確認・`infra/bootstrap` のローカル state からの `agent_mcp_role_arn` 自動検出・`~/.aws/config` への `agent-mcp` プロファイル書き込み・`sts get-caller-identity` による疎通確認までを自動化する。既存の `login` 動作（サブコマンド未指定時）は完全に後方互換。
- **`infra/bootstrap` の state を S3 へ自動バックアップし、`recover` でまず復元を試みるようにした**: `infra/bootstrap` はチキン&エッグ制約でローカル state 限定のため、それを持つ唯一のマシンを失うと `terraform import` ベースの `recover` しか復旧手段が無かった。`init`/`update` 成功後（および `recover` の import フォールバック成功後）に state バケット内の `_bootstrap-state-backup/` へ自動アップロードするようにし、`recover` はローカルに state が無ければまずこのバックアップからの復元を試み、成功すれば import を実行せずに完了するようにした。
- **HashiCorp Terraform MCP Server を `.mcp.json` に導入**: Terraform Registry のプロバイダー/モジュール仕様参照用に、`hashicorp/terraform-mcp-server:1.1.0`（Docker 起動）を project scope で追加した。実機で MCP の initialize ハンドシェイクと `tools/list` のスキーマ登録までは確認したが、実際の Terraform Registry 参照呼び出しは検証セッションのネットワーク制限により未確認のまま（通常のネットワーク到達性がある環境での再確認が必要）（#573）。
- **MCP サーバー選定方針・Serena MCP 導入の提案書を追加**: `docs/proposal/mcp-server-selection-proposal.md`（AWS MCP Server を中核とした選定方針、少数精鋭・公式優先の原則、段階導入計画、#568/closes #566）と `docs/proposal/serena-mcp-adoption-proposal.md`（LSP ベースのコード操作 MCP の試験導入、目的・設定設計・効果測定計画・撤退条件、#567/closes #565）を作成した。両提案書が前提にしていた「`itouhi/terraform` の設定内容を確認して整合を取る」という未解決点は、同リポジトリの破棄により対象を失ったため解消済みと訂正した（#569）。
- **copier `update` が機能するよう `.copier-answers.yml` を生成するようにした**: `copier.yml` が `.copier-answers.yml.jinja` を用意していなかったため、生成した下流プロジェクトに `.copier-answers.yml` が書き込まれず、`copier update` が「テンプレート参照を取得できない」で即エラーになり、テンプレート更新への追従が原理的に不可能だったことを実機確認した。`.copier-answers.yml.jinja` を追加して解消し、置換ループが本物のテンプレート参照元（`_src_path`）まで書き換えないよう除外した。実機検証として、18件超の PR 分のドリフトを挟んで `copier update` がコンフリクトなく反映されること、下流でのローカル変更が上流の変更と衝突する場合は標準的な git 風コンフリクトマーカーが挿入されることを確認した。`README.md` に生成先向けの実行手順を追加し、破壊的変更は該当 CHANGELOG エントリに明記する運用とした（#298 PR1、#554, #555）。
- **WSL2 での Docker DNS 未到達による MCP サーバー障害の対処法を追記**: WSL2 上に Docker デーモンを立てている環境では DNS 解決が壊れ、`docker run` 経由の MCP サーバー（Terraform MCP 等）が外部レジストリに到達できないことがある（Codespaces では非再現）。`docs/development-environment.md` のトラブルシューティング表に対処法を追記した（#570）。

### Changed

- **devcontainer 事前ビルドキャッシュの `cacheFrom` から不要な `:latest` を除去**: v0.5.3 で `docker` ドライバのキャッシュヒットのため `cacheFrom` に inline cache 対応の `:latest` を追加していたが、`:buildcache`（registry cache）単体でも `docker-container` ドライバ下で問題なくキャッシュヒットするかを実機で切り分けた。実際に Codespaces を新規作成し、`Dockerfile` 由来の `RUN` 14件全てが `CACHED` になることを確認できたため `:latest` を外した。設計判断の訂正は [ADR-0018](docs/adr/0018-devcontainer-image-ghcr-cachefrom.md) 訂正6参照（#552, #553）。

## [0.5.3] - 2026-07-18

### Fixed

- **devcontainer 事前ビルドキャッシュが実際の Codespaces では引き続き機能しなかった不具合を修正**:
  v0.5.2（`:buildcache` 単体参照）リリース後の実機テストで、Codespaces が実際に使う buildx
  `docker` ドライバでは `type=registry` 形式のレジストリキャッシュ（`:buildcache`）を読み込め
  ないことが判明した（`docker-container` ドライバ限定の制約）。まず `cacheFrom` に inline
  cache 対応の `:latest` を追加したが（#547）、それでも実際の Codespaces では `RUN` が1件も
  キャッシュヒットしなかった。ホスト側 Docker Engine（`moby-engine` 24.0.x 系）で containerd
  snapshotter が無効なためと推測し、devcontainer spec の `initializeCommand`（コンテナビルド
  前にホスト側で実行される）から buildx builder を `docker-container` ドライバへ切り替える
  対応を追加した（#548）。`docker buildx use` はリポジトリ単位ではなくホスト全体のグローバル
  設定を書き換えるため、ローカルの VS Code Dev Containers 拡張へ副作用が及ばないよう
  `CODESPACES=true` の場合のみ実行するようガードした（#550）。実際に Codespaces を新規作成し、
  `Dockerfile` 由来の `RUN` 13件全てが `CACHED` になることを実機確認済み。設計判断の詳細は
  [ADR-0018](docs/adr/0018-devcontainer-image-ghcr-cachefrom.md) 訂正4・訂正5参照（#546）。

## [0.5.2] - 2026-07-17

### Fixed

- **`devcontainer-build.yml` が Codespaces / VS Code Dev Containers の実際のビルド経路と
  異なるグラフで `:buildcache` を作っており、キャッシュが恒久的にミスしていた不具合を修正**:
  `docker/build-push-action` で生の `.devcontainer/Dockerfile` を直接ビルドしていたが、
  Codespaces / VS Code Dev Containers は `devcontainer.json` の `features`
  （`docker-in-docker`）組み込みのため、ベースステージを `dev_container_auto_added_stage_label`
  にリネームし `_DEV_CONTAINERS_*` build-arg と追加ビルドコンテキストを注入した別のビルド
  グラフでビルドする。BuildKit のレジストリキャッシュは `FROM` 起点の op ダイジェストチェーン
  で一致判定するため、この構造差により公開した `:buildcache` が実際の Codespaces ビルドで
  一切再利用されなかった（実機確認: `devcontainer-build.yml` 自身の直近実行ログでも `CACHED`
  が0件）。GHCR パッケージの可視性・認証は問題なくアクセス権の問題ではなかった。
  `devcontainer-build.yml` を `devcontainer build`（`@devcontainers/cli`）経由のビルドに
  変更し、実際の消費経路と同じグラフに対して `:buildcache` を作るようにした。ローカルで
  既存の `:buildcache` に対して `devcontainer build --cache-from` を実行し、全 `RUN` ステップ
  が `CACHED` になることを実機確認済み。設計判断の訂正は
  [ADR-0018](docs/adr/0018-devcontainer-image-ghcr-cachefrom.md) 参照（#542）。

## [0.5.1] - 2026-07-17

### Fixed

- **`verify-scaffold.sh` が公開ミラー経由で `devcontainer` を未置換残存と誤検知する不具合を修正**:
  置換漏れチェックの `devcon` パターンに単語境界が無く、`publish-to-public.sh` が
  このスクリプト自身も含めて `devcon` → `devcon` を無差別置換すると、公開ミラー
  （`iwata-jawsug-jp/devcon`）側では実行時にこの行が単語境界なしの `devcon` パターンになり、
  `devcontainer` という頻出語の先頭一致を誤検知していた（v0.3.14 以降の全リリースで
  公開ミラーの `scaffold` ジョブが失敗）。`copier.yml` の `_tasks` が同じ理由で既に
  `\bdevcon\b` としているのと同じ対策を適用した（#536）。
- **devcontainer 事前ビルドの `cacheFrom` が未 publish な名前空間を参照していた不具合、および
  `tags`/`cache-to` のタグ衝突で実イメージが破壊される不具合を修正**: `devcon` 自身の
  `devcontainer.json` が、公開ミラーへの publish 時にのみ書き換わる想定だった
  `ghcr.io/iwata-jawsug-jp/devcon/devcontainer:latest` を参照していたため、`devcon`
  自身は Rebuild Container してもキャッシュの恩恵を一切受けられなかった。また
  `devcontainer-build.yml` の `tags` と `cache-to`（`mode=max`）が同じ `:latest` タグを
  共有しており、`cache-to` が書き込む buildkit cache config manifest が実イメージを
  上書きしていたことを実機（`docker buildx imagetools inspect --raw` および実際の
  `docker build --cache-from` 実行）で確認した。`cacheFrom` を公開ミラーの canonical な
  イメージへの直接参照に変更し、`cache-from`/`cache-to` を `tags` とは別タグ（`:buildcache`）
  に分離した。設計判断の訂正は [ADR-0018](docs/adr/0018-devcontainer-image-ghcr-cachefrom.md)
  参照（#538）。

## [0.5.0] - 2026-07-17

### Added

- **`bootstrap.sh` に別マシンでの設定取り込み（`adopt`）と state 復旧（`recover`）を追加**:
  `infra/bootstrap` はローカル state 限定のため、`init` を実行した1台以外の開発PCでは
  bootstrap 設定を使えず、その1台自体を失うと AWS 上にリソースが残っていても復旧手段が
  無かった。`adopt` は `write` が公開済みのリポジトリ変数（`PROJECT_NAME` /
  `AWS_TF_STATE_BUCKET` / `AWS_PLAN_ROLE_ARN` / `AWS_DEPLOY_ROLE_ARN`）を読み、現在の
  AWS 認証情報で state バケット・IAM ロール2つの実在を確認したうえで
  `infra/env/*.backend.hcl` / `*.tfvars` を生成する（ローカル state は作らない）。
  `recover` は同じ検証を行ったあと `terraform import` で `main.tf` の全 managed resource
  （state バケット一式・IAM ロール2つ・ポリシー8個・アタッチメント9個・inline ポリシー2個）
  を再構築し `terraform.auto.tfvars` も書く。既に import 済みのリソースはスキップするため、
  一部失敗しても再実行で再開できる（#530）。
- **devcontainer イメージを GHCR に事前ビルド公開し `build.cacheFrom` で取り込むようにした**:
  devcontainer 初回起動が `.devcontainer/Dockerfile` の完全ローカルビルドで遅い問題に対応。
  `image` への全面移行ではなく `build.cacheFrom` を追加する方式を採用し、`Dockerfile` 編集
  → ローカル即 Rebuild Container という既存の開発者体験を維持しつつ初回起動を高速化した。
  公開は公開ミラー（`iwata-jawsug-jp/devcon`）側でのみ実行するようジョブガードし、
  開発用リポジトリ自身が誤って自分の名前空間に push しないようにした。設計判断は
  [ADR-0018](docs/adr/0018-devcontainer-image-ghcr-cachefrom.md) 参照（#532, #534）。

### Fixed

- **`check-devenv-setup.sh` が `terraform init` 未実行を `infra/bootstrap` 未適用と誤判定する
  不具合を修正**: 判定が `terraform -chdir=infra/bootstrap output` の成否のみに依存しており、
  実際には適用済みでもこのチェックアウトでプロバイダプラグイン未キャッシュ（コンテナ再構築
  直後等）だと「未適用」と誤表示していた。`terraform.tfstate` に managed resource が実在
  するかを python3 で直接確認するフォールバックを追加し、「本当に未適用」と「適用済みだが
  このチェックアウトで `terraform init` 未実行」を区別するようにした（#529）。

## [0.4.0] - 2026-07-17

### Added

- **Codespaces で Claude Code のオンボーディング/信頼ダイアログを事前承認する `make claude-setup` を追加**:
  新規 GitHub Codespaces 作成時、`~/.claude` の名前付きボリュームが空のため初回オンボーディング
  画面と「このフォルダを信頼しますか」トラストダイアログが毎回出る問題に対応した。
  `tools/script/claude-codespaces-setup.sh` が `~/.claude/.claude.json` に
  `hasCompletedOnboarding: true` とこのリポジトリの `hasTrustDialogAccepted: true` を、
  既存ファイルがあれば該当2キーだけをマージする形で書き込む（#526）。
- **`docs/development-environment.md` に Codespaces Secrets 経由の認証永続化手順を追記**:
  Claude Code の非対話認証（Pro/Max サブスクリプションなら `claude setup-token` で発行した
  トークンを `CLAUDE_CODE_OAUTH_TOKEN`、API キー課金なら `ANTHROPIC_API_KEY`）と、npm の
  GitHub Packages（private）を `PACKAGE_USERNAME` / `PACKAGE_REPO_TOKEN` で使う手順を、
  いずれも個人アカウントの Codespaces Secrets に登録すれば新規 Codespace でも引き継がれる
  こととあわせて記録した（#524, #525）。

### Fixed

- **`check-devenv-setup.sh` が Codespaces Secrets 経由の Claude Code 認証を誤検知する不具合を修正**:
  `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY` による非対話認証を使う場合、Claude Code が
  それを検出して対話ログイン自体をスキップするため `~/.claude/.credentials.json` が
  作られず、「未ログイン」と誤判定していた。この2つの環境変数も有効な認証状態として
  扱うよう修正した（#527）。
- **`check-devenv-setup.sh` の `gh` 権限不足によるリポジトリ変数の誤判定を修正**: `gh variable
list` の失敗（権限不足など）をstderrごと握りつぶしていたため、実際は登録済みかもしれない
  `AWS_TF_STATE_BUCKET` 等の変数まで一律「未登録」と誤表示していた。取得成否を先に判定して
  から分岐するよう変更し、取得自体の失敗は「権限不足で確認できない」旨の情報表示にした
  （#519）。
- **`reusable-infra.yml` の Checkov ステップが working-directory の二重適用でスキャン対象0件
  だった問題を修正**: `defaults.run.working-directory: infra` が設定された `check` ジョブで
  `checkov -d infra` が実際には `infra/infra` を探しに行き、`--soft-fail` により無検査のまま
  green になっていた。`checkov -d .` に修正した（#521）。
- **`bootstrap.sh write` が `gh` 権限不足時に `infra/env` 生成まで巻き添えで止まる不具合を修正**:
  `gh variable set` が権限不足で失敗すると `set -euo pipefail` によりスクリプトがその場で
  強制終了し、後続の GitHub とは無関係な `infra/env/*.backend.hcl` / `*.tfvars` 生成処理まで
  実行されなくなっていた。4件の `gh variable set` をまとめて成否判定し、失敗してもスクリプト
  本体は継続して生成処理まで到達するよう修正した（#522）。

## [0.3.14] - 2026-07-17

### Fixed

- **copier スキャフォールド生成物への `.git` 混入バグを修正**: `copier.yml` の `_exclude` を
  自前定義すると copier 標準の除外（`.git`・`copier.yml`・`copier.yaml`・`~*`・`*.py[co]`・
  `__pycache__`・`.DS_Store`・`.svn`）が継承されず丸ごと上書きされる仕様のため、
  `copier copy` の生成物に devcon 本体の全コミット履歴（`.git/`、90MB）と
  `copier.yml` 自体がそのまま複製されていた。標準除外を明示的に足し戻して解消し、
  `verify-scaffold.sh` に混入検出のアサーションを追加した（#515）。
- **`docs/adr/*` の生成物除外リストの drift を解消**: `0001`〜`0011` の個別ファイル名列挙が
  その後追加された `0012`〜`0017`（6件）に追従できておらず、生成物にそのまま出力されて
  いた。glob パターン（`docs/adr/*.md` + `!docs/adr/template.md`）に置き換え、
  `docs/org-rulesets.md`・`docs/frontend-frameworks-demo.md` も除外に追加した（#515）。
- **公開ミラー（`iwata-jawsug-jp/devcon`）経由の `copier copy` で `.devcontainer` が
  破損するバグを修正**: `publish-to-public.sh` が `copier.yml` の中身も含めて
  `devcon`→`devcon` を無差別置換するため、公開ミラー側の `copier.yml` では
  `_tasks` の置換パターンが `s#devcon#...#g` になり、`devcontainer` という頻出語の
  先頭一致で `ghcr.io/devcontainers/...` 等を破壊していた。`devcon` パターンだけ
  `\b` で単語境界を要求して解消した（他の3パターンは Cognito ユーザープールID形式
  `ap-northeast-1_xxxxxxxxx` を壊すため意図的に境界なしのまま）（#515）。

## [0.3.13] - 2026-07-16

### Added

- **Policy as Code（conftest/OPA）を導入**: 汎用スキャナ（tflint/checkov/trivy）や
  accessanalyzer 検証（ADR-0009）が対象としない、このリポジトリ固有の規約を
  `infra/policy/*.rego` で機械検証する層を追加した（#296、[ADR-0017](docs/adr/0017-policy-as-code-conftest.md)）。
  `cd-infra.yml` の plan ジョブが既に生成していた plan JSON に1ステップ足すだけで配線でき、
  新規の JSON 化パイプライン構築は不要だった。初期ポリシーとして必須タグ・IAM ワイルドカード
  アクション禁止を導入し（PR1、#509）、続けて #364/#285 の実機検証で発見されたバグクラスの
  再発防止として、region 依存アクションへの `aws:RequestedRegion` 条件必須化・NAT 無し構成の
  VPC エンドポイント確認・CSP `connect-src` の Cognito オリジン確認・ECS/フロントエンドへの
  Cognito 関連環境変数注入確認を追加した（PR2、#512）。

### Fixed

- **tflint が GitHub Attestations API の破壊的変更でクラッシュする問題を回避**:
  2026-07-16 に GitHub の Attestations API から `bundle` フィールドが削除された影響で、
  tflint の AWS プラグインの attestation 検証が nil pointer で panic し、`infra/**` を
  変更する全 PR の `ci.yml` が影響を受けていた（upstream:
  [terraform-linters/tflint#2591](https://github.com/terraform-linters/tflint/issues/2591)）。
  `.tflint.hcl` の AWS プラグインを legacy PGP 署名検証にフォールバックさせて回避した
  （一時的な対応、アップストリームの修正を待って戻す予定）。副次的に、`.tflint.hcl`/
  `.trivyignore` の変更が `ci.yml` の infra path フィルタの対象外だったため、この修正自体が
  CI で検証できない状態だったことも発見・修正した（#510, #511）。

## [0.3.12] - 2026-07-16

### Added

- **`infra/bootstrap` init/update/write/destroyスクリプトを追加**: 手作業だった
  bootstrap の apply（`terraform apply`への`-var`手入力、`gh variable set`3行の
  コピペ、`infra/env/*.backend.hcl`/`*.tfvars`の手書き）・破棄手順の欠如を
  `tools/script/bootstrap.sh`に集約した。GitHub org/repo・AWSアカウントIDを
  自動検出し、state バケット名（`terraform-<project>-<account_id>-<random6>`）を
  自動生成、既存のGitHub Actions OIDCプロバイダーの有無も検出して重複作成を
  避ける（#491, #492）。

### Fixed

- **`bootstrap.sh destroy`でOIDCプロバイダーの削除有無を個別確認するよう修正**:
  `destroy`の既定target一覧に`aws_iam_openid_connect_provider.github`が無条件で
  含まれており、このbootstrapがOIDCプロバイダーを作成していた場合は他のリソースと
  一緒に削除されてしまっていた。同じAWSアカウントを共有する別リポジトリの
  bootstrapが`create_oidc_provider=false`でこれを再利用している場合、削除すると
  そちらのCI認証が壊れるため、`--include-oidc-provider`オプションを追加し、
  指定時も`-y`/`--yes`ではスキップされない個別のy/N確認を必ず挟むようにした
  （#493）。
- **`bootstrap.sh`の状態判定・乱数生成バグを修正**: `has_state()`が
  `terraform output`の終了コードのみで判定していたため、state が全く無い環境
  でも常に「already applied」と誤検知していた（`terraform output`はstate皆無
  でも`Warning: No outputs found`を出すだけでexit code 0を返す）。
  `terraform state list`の中身で判定するよう修正した。また`random6()`は
  `set -euo pipefail`下で`tr -dc 'a-z0-9' </dev/urandom | head -c6`が`head`側の
  早期クローズにより`tr`がSIGPIPEで非ゼロ終了し、呼び出し元の`bucket=...`代入
  ごとスクリプトがエラーメッセージ無しに無言終了するバグもあり、あわせて修正
  した。
- **CIのbackend/tfvars materializeがbootstrapのproject名を考慮していなかった**:
  `infra/env/*.backend.hcl.example`のstate keyと`*.tfvars.example`のprojectは
  `"devcon"`のリテラルプレースホルダで、ローカルの`bootstrap.sh write`は
  これをbootstrap実行時のproject名へsedで置換するが、`cd-infra.yml`ほかCI側の
  materializeステップはstateバケット名しか置換しておらず、`devcon`
  以外のproject名でbootstrapを適用すると、state key prefixとIAMポリシー
  （`ci_plan`の`${var.project}`スコープ）が食い違い、state lockオブジェクトへの
  `s3:PutObject`が`AccessDenied`になっていた。新規リポジトリ変数
  `PROJECT_NAME`（`bootstrap.sh write`が自動設定）を導入し、CI側4ワークフロー
  （`cd-infra.yml`/`cd-infra-verify.yml`/`cd-sandbox-cycle.yml`/
  `cd-infra-sandbox.yml`、計8箇所）のmaterializeステップにも同じ置換を実装
  した。あわせてMakefileの`bootstrap-init`/`update`/`write`/`destroy`・
  `check-iam-policies`ターゲットを削除し、`tools/script/bootstrap.sh`を直接
  呼ぶ運用に統一した（#494）。

## [0.3.11] - 2026-07-15

### Fixed

- **週次エフェメラルサイクル（`cd-sandbox-cycle.yml`）が`main`からの`workflow_dispatch`で
  Terraform initに失敗する**: `env/sandbox.{backend.hcl,tfvars}`はgit-ignore対象で、
  `sandbox/*`ブランチのような事前コミットが存在しない`main`起点の実行では欠如したまま
  だった。`cd-infra.yml`と同じ「`.example`から実行時に生成する」ステップを`apply`/
  `teardown`両ジョブに追加した（#479）。
- **同サイクルの`apply`が作り直したAWSリソースIDを後続ジョブが読まず、固定の
  `vars.SANDBOX_*`を参照していた**: `apply`のたびに変わるsubnet ID・CloudFront
  distribution ID・Cognito user pool/client ID等を、`deploy-api`/`frontend`/
  `smoke-test`が過去に人手で一度だけ設定したリポジトリ変数から読んでおり、
  `InvalidSubnetID.NotFound`/`NoSuchDistribution`で失敗していた。`apply`ジョブで
  `terraform output`をexportし、後続ジョブは`needs.apply.outputs.*`を参照するよう
  配線し直した。`infra/outputs.tf`に`cognito_hosted_ui_domain_prefix`outputを追加
  （#482）。
- **`cd-infra-sandbox.yml`の`destroy`ジョブも同じ理由でTerraform initに失敗する**:
  `apply`/`destroy`冒頭コメントの「`env/sandbox.*`がsandboxブランチに事前コミット
  されている」という前提が実運用と食い違っていた（`cd-sandbox-cycle.yml`が作成した
  環境を`destroy`しようとすると発生）。同じ実行時生成ステップを追加し、前提の記述も
  実態に合わせて修正した（#484）。
- 上記3件はsandbox実機（apply→deploy-api→frontend→smoke-test→teardown完走）で検証済み。
  検証中に副産物として発見した`infra/bootstrap`未適用によるIAM権限欠如（#488）も解消した。
- `docs/infrastructure.md`の`main-ci-requiredルールセット`更新コマンド例を、動作する
  JSON `--input`版に修正した（#483）。

## [0.3.10] - 2026-07-15

### Added

- **プラットフォーム成熟度スコアカードの自動生成**: `.github/ISSUE_TEMPLATE/verification.md`に
  ラベルのみ存在していた10軸（開発環境の標準化・CI/CD・品質ゲート等）について、1〜5点の
  採点基準とGolden Path/IDP2つの総合点への集約方法を新規に定義した
  （`docs/metrics/scorecard-criteria.md`、#297）。`docs/metrics/scorecard/catalog.json`の
  宣言スコアと、リポジトリ内の機械信号（ファイル存在・grepパターン検出・GitHub Actions実行
  履歴）を突き合わせてドリフトを検知する`.github/scripts/scorecard_metrics.py`と、DORA計測
  （#237）と同型の`.github/workflows/metrics-scorecard.yml`（`workflow_dispatch`のみ、
  `docs/metrics/scorecard/`に月次スナップショット保存）を追加した（ADR-0014）。品質ゲート軸には
  live-smokeゲート（#376）の直近成功日時をGitHub API経由で判定するチェックも追加した。
- **live-smokeゲートをreusable workflow化**: `cd-app-sandbox.yml`/`cd-app.yml`/
  `cd-sandbox-cycle.yml`の3ワークフローに重複していたdisposable Cognitoユーザー作成→
  live-smoke実行→アーティファクトアップロード→ユーザー削除というジョブ（約270行）を
  `.github/workflows/reusable-live-smoke.yml`に統合した（#376、ADR-0015）。CI側の
  reusable workflow化（#295、ADR-0012）と同じ「mechanismは共有・policyは呼び出し側」という
  設計原則をCD側にも適用し、週次エフェメラルサイクル（`cd-sandbox-cycle.yml`）も
  この統合対象に含めた。

### Changed

- **AI-DLC（awslabs/aidlc-workflows）の取り込みを見送り**: フォルダー構成・取り込みサイクル・
  ライセンスの3観点で検討した結果、公式のClaude Code導入手順が`CLAUDE.md`を丸ごと上書きする
  方式で、`docs/ai-instructions.md`の一本化原則およびADR-0002（cc-sdd採用時に明文化した
  「CLAUDE.mdを外部ツールに所有させない」制約）と衝突すること、AI-DLCのフェーズゲート型
  ワークフローが既採用のcc-sddと機能的に重複することから、全面採用を見送る判断を記録した
  （ADR-0013）。

## [0.3.9] - 2026-07-14

### Added

- **スキャフォールドCLI（copier）を導入**: `copier copy gh:iwata-jawsug-jp/devcon <生成先>`
  一発で、プロジェクト名・GitHub org/repo・AWSリージョンを指定した「命名済み」の新規プロジェクトを
  生成できるようにした（#294）。ツール選定は cookiecutter・GitHub template repo と比較し
  `copier update` による下流追従を決め手に採用（ADR-0010）。テンプレートは本リポジトリ自身とし、
  専用リポジトリへは切り出さない（ADR-0011 — 第2消費者実証 `itouhi/devcon-test` が既に
  devcon 自身の fork として動いている実績、`tools/script/publish-to-public.sh` の
  除外リスト＋文字列置換という前例を踏まえた判断）。テンプレート化の機構は当初 Jinja 直書き方式
  を検討したが、in-place テンプレートの前提（devcon 自身が常に動く状態を保つ）と矛盾する
  ため、`publish-to-public.sh` と同じ「コピー後に sed で置換する」方式（copier の `_tasks`）に
  修正した。生成物は `make scaffold-verify`（`ci.yml` の `scaffold` ジョブ）で継続的に検証する。
- **CI を reusable workflow 化**: `ci.yml` と `ci-sandbox.yml` の per-area 品質ゲート
  （backend/frontend/infra/scripts/scaffold）を `reusable-*.yml`（`workflow_call`）へ抽出し、
  両ワークフロー間の drift（#153 指摘7 — 実際に diff を取ると `ci-sandbox.yml` は DESIGN.md
  lint・バンドル予算・Lighthouse CI・E2E・`scripts`/`scaffold` ジョブが丸ごと欠落していた）を
  構造的に解消した（#295、ADR-0012）。`.github/CODEOWNERS` の雛形も追加した。

### Fixed

- **`workflow_call` の status check 名の不整合**: reusable workflow 化に伴い check 名が
  `<呼び出し側ジョブ名> / <内側ジョブ名>` に変わることを実地検証で確認し、`main-ci-required`
  ルールセットを追従させた。さらに、呼び出しジョブを `if:` で丸ごとスキップする設計のままだと
  スキップ時のみ check 名がサフィックス無しの別名になり、該当エリアを変更しない大多数の PR が
  マージ不能になる問題を発見・修正した（呼び出しは常に行い、スキップ可否は `should_run` 入力で
  内側のジョブに渡す方式に変更）。

## [0.3.8] - 2026-07-13

### Added

- **認可scope追加時の3点セットをSDD運用に定型化**: 第2消費者実証（itouhi/devcon-test）で、
  フロントのOIDCログインscope要求リストへの追加がタスク分解から漏れた実例（devcon-test#20）を
  受け、`infra/auth.tf`のresource server・バックエンドの`require_scope`・フロントの
  `oidcConfig.ts`scope定数の3点セットを`.kiro/steering/tech.md`に明記した。加えて、両者の
  食い違いを静的に検出する`.github/scripts/check_oauth_scopes.py`を追加し、
  pre-commit/`make lint`/CIの3層に配線した（#438）。
- **IAMポリシーの実在しない条件キーを検出する静的ゲートを追加**: `terraform validate`/
  tflint/checkovの全ゲートを素通りする「条件キーの誤字によるステートメントの無言の無効化」
  （#338）を、`aws accessanalyzer validate-policy`で検出する
  `.github/scripts/check_iam_policies.py`を追加した。app層は`cd-infra.yml`のplanジョブで
  自動検証し、`infra/bootstrap/`（CI外・人力apply運用）は`make check-iam-policies`で
  別途検証する2層構成とした（ADR-0009、#340）。
- **週次エフェメラルサイクルワークフローを追加**: `cd-sandbox-cycle.yml`がsandbox環境の
  `apply → deploy → live-smoke → teardown`を1回の`workflow_dispatch`実行で完走させ、
  長寿命のsandbox環境では原理的に再現しない「ゼロからのプロビジョニング特有の欠陥」
  （#436/#437と同クラス）を定期的に検出できるようにした。`TF_ENV=sandbox`が単一の共有state
  であるため、`schedule`トリガーは意図的に未設定（#376 PR④）。
- **`check-devenv-setup.sh`がClaude Code / GitHub Copilot CLIのどちらか一方で通るように対応**:
  これまで`claude`必須だったAIコーディングエージェントCLIのチェックを、`claude`/`copilot`
  いずれかの実装で良いように変更した（#117関連）。

### Changed

- **X-Rayトレース確認手順をdocsに追記**: ADR-0007で実装済みの分散トレーシングについて、
  AWSコンソールでのトレース確認手順（Service map・Traces検索・構造化ログの`trace_id`との
  相関）を明文化した。Grafana等の追加ダッシュボード（OBS-02）は、現状のX-Rayコンソール
  標準機能で完了条件を満たせているため対象外と判断した（#410）。
- **CI運用定着タスク（CI-01/CI-02）の判断を記録**: CI実行時間トレンドの可視化は実測で
  明確なボトルネックが無いため現時点で見送り、pre-commitフックの定着状況は確認済みで
  あることを記録した（#409）。

### Fixed

- **bootstrap deployロールのregion条件（18箇所の重複）を`dynamic "condition"`ブロックへ
  集約**: 同一の`aws:RequestedRegion`条件が18ステートメントにコピペされており、将来の
  変更漏れによるリージョン制約の意図しない解除リスクがあった。`local.region_condition`
  から単一定義で展開する形にリファクタした（#285）。

## [0.3.7] - 2026-07-12

### Fixed

第2消費者実証（itouhi/devcon-test、v0.3.3のfork）の sandbox デプロイで顕在化した3件の不具合を修正。

- **S3バケット名・Cognito Hosted UIドメイン名をアカウントIDでグローバルに一意化**: `local.name_prefix`
  をS3バケット名・Cognitoドメインにそのまま使っていたが、両者はAWSアカウントを跨いでグローバルに
  一意な名前空間のため、`project`の既定値のままforkした複数の利用者・環境が同時にデプロイすると
  衝突していた。`local.global_name_prefix`（`name_prefix` + account_id）を追加し、S3バケット名・
  Cognitoドメインにのみ適用（アカウント内一意で十分なVPC/ALB/RDS等は`name_prefix`のまま）。
  命名規約を`infra/CLAUDE.md`に明記（#436）。
- **deployロールに`ec2:GetSecurityGroupsForVpc`を追加**: ゼロからのプロビジョニングでELBv2の
  `CreateLoadBalancer`（`aws_lb.api`）がこのアクションの欠如によりAccessDeniedで失敗していた。
  長寿命のsandbox環境ではALBが既に存在するため露見せず、ゼロから環境を立ち上げる経路でのみ
  踏むIAM穴だった（#437。`infra/bootstrap/`はCI外・人力apply運用の層のため、実AWSへの反映は
  別途人力での`terraform apply`が必要）。
- **CloudFrontのエラーマスキング（403/404→200）を`/api/*`に適用しない構成に変更**: distribution
  単位の`custom_error_response`（SPAのクライアントサイドルーティング救済策）が`/api/*`ビヘイビア
  にも適用され、APIの正当な403/404がブラウザから「200 + SPAのHTML」に化けて観測不能になり、
  E2Eからの権限系バグ検出を阻害していた。SPAルーティングのフォールバックを、リクエスト側
  （viewer-request）で解決するCloudFront Functionに置き換え、`default_cache_behavior`（S3
  オリジン）にのみ関連付けることで`/api/*`に一切影響しないようにした。live-smokeに、存在しない
  `/api/*`パスが素の404で返ることを検証するケースを追加（#439）。

## [0.3.6] - 2026-07-12

### Added

- **`make check-setup` が GitHub Rulesets（ブランチ保護）も検証するように**: 開発環境の
  初期セットアップ確認スクリプト `tools/script/check-devenv-setup.sh` に、リポジトリ側で
  設定が必要な `main-ci-required` / `sandbox-isolation` ルールセットの確認を追加した。
  当初は存在チェックのみだったが、`enforcement`（active か）・`target`（branch か）・
  対象ブランチ（`ref_name.include`）・必須ステータスチェックの4点まで検証する
  `check_ruleset` 関数に発展させた。この強化により、`sandbox-isolation` の対象ブランチが
  `docs/sandbox.md` の記載（当初 `~ALL`）と実際の設定が食い違っていることを実機で検出した。
- **`docs/infrastructure.md` / `docs/sandbox.md` にルールセット作成手順とスクリーンショットを
  追加**: `main-ci-required` / `sandbox-isolation` それぞれについて `gh api` での作成例と
  GitHub UI（Settings → Rules → Rulesets → New ruleset）での手順を明文化し、対応する
  設定画面のスクリーンショットを添えた。
- **`docs/development-environment.md` に `make check-setup` の実行例スクリーンショットを追加**。

### Fixed

- **`sandbox-isolation` ルールセットの対象ブランチを `~ALL` から `~DEFAULT_BRANCH` に修正**:
  `sandbox-guard.yml` の `guard` ジョブは `pull_request` イベントでのみ起動するため、
  対象を `~ALL`（全ブランチ）にすると、まだ PR の無い新規ブランチの **push 時点**で
  `guard` が一度も走っておらず必須ステータスチェックを満たせない。実際にこの変更を
  適用した結果、**リポジトリ全体で新規ブランチの push がブロックされる障害**が発生した
  ため、`~DEFAULT_BRANCH`（`main` へのマージ時のみ強制）に戻し、`~ALL` を避けるべき理由を
  `docs/sandbox.md` に明記した。`docs/sandbox.md` の GitHub UI 経由でのルールセット作成
  手順にも、`gh api` 例と同じ `sandbox-isolation` という名前を明示的に指定する記載が
  抜けていたため追記した（`make check-setup` が参照する名前と一致させるため）。

## [0.3.5] - 2026-07-12

### Added

- **IAM Identity Center を使わない一時クレデンシャル発行手順を追加**: `docs/aws-temporary-credentials.md`
  を新設し、AWS Organizations 未導入のアカウント（個人アカウント等）向けの代替手法を 4 つ
  収録した — IAM ユーザー + `get-session-token`（推奨）／IAM ユーザー + `assume-role`／
  IAM Roles Anywhere／AWS CloudShell 経由でのコピー。長期シークレットの有無・有効期間・
  セットアップの重さを比較表にまとめ、`README.md`「AWS SSO 初期設定」・`docs/README.md`
  索引・`CLAUDE.md`「More detail」から相互参照を追加した。

## [0.3.4] - 2026-07-12

### Added

- **新規 AWS アカウント/リージョンでの `infra/bootstrap` 初回 apply 時に `alias/aws/rds` /
  `alias/aws/secretsmanager` が未生成で失敗するケースの対処法を追記**: これらの AWS 管理
  KMS キーのデフォルトエイリアスは該当サービスを一度も使っていないアカウントでは遅延生成
  されず存在しないため、`terraform apply` が `Error: reading KMS Alias ...: empty result`
  で失敗する。ダミーシークレットの作成/削除でキーを温める手順を
  `infra/bootstrap/README.md` と `docs/infrastructure.md` に記録。
- **`docs/development-environment.md` に `gh auth login` の初回対話フローを追記**: 新規
  開発環境セットアップ時に `gh auth status` が未ログイン状態を返すのは想定挙動だが、そこから
  ログインを完了させるまでの流れ（対話プロンプト例・完了確認方法）がドキュメントに無かった
  ため追記。
- **開発環境の初期セットアップ項目を一括確認する `tools/script/check-devenv-setup.sh` を追加**:
  コンテナ同梱ツール・`make setup`（backend/frontend 依存 + pre-commit フック）・
  gh/Claude Code/AWS SSO の各ログイン・（任意で）自分の AWS にデプロイする場合のリポジトリ
  変数登録状況を一括確認できる。`make check-setup` から実行可能。`ssh -T git@github.com` が
  認証成功時も exit 1 を返す GitHub 側の仕様により、`pipefail` 下で `ssh | grep` に直結すると
  誤って NG 判定になる不具合を実機検証で発見し修正済み。

## [0.3.3] - 2026-07-12

### Added

- **`docs/development-process.md` を新設**: `docs/proposal/application-development-process-proposal.md`
  で採用・実施済みだったアプリケーション開発プロセス（要件定義〜リリースの全体フロー・
  sandbox 検証要否の判定表・ブランチ戦略）を、`docs/proposal/` は公開ミラー対象外
  （読者に届かない）という理由で `docs/` 直下へ昇格。`infrastructure.md`/`sandbox.md`/
  `issues.md` の相互参照リンクも新ドキュメントへ差し替えた。

### Changed

- **公開リポジトリの issue テンプレートを `bug-report.md` のみに変更**: 従来は
  `config.yml`（`blank_issues_enabled`）のみを公開し、テンプレート本体は全て
  除外していたため、公開リポジトリでは実質ブランクissueしか使えない状態だった。
  `bug-report.md` の文面を英語化したうえで公開対象に切り替え、`config.yml` は除外に
  戻した（`chore.md`/`feature-sdd.md`/`verification.md` は引き続き運用検証中のため
  除外のまま）。

### Fixed

- **README/CLAUDE.md/Copilot instructions 間の不整合5件を修正**:
  `services/frontend/README.md` の build スクリプト説明が vite-ssg 移行（#78）に
  追従しておらず `vite build` のままだった／ルート `CLAUDE.md` の「More detail」に
  `docs/development-process.md` が未掲載だった／`.github/copilot-instructions.md` に
  「CI green はデプロイ動作を保証しない」第4のゲートのルールが丸ごと欠落していた／
  `.github/instructions/infra.instructions.md` に `INFRA_APPLY_ENABLED` の記載漏れ／
  `.github/instructions/backend.instructions.md` にテストDB（既定SQLite・CIはPostgres）
  の記載漏れ。後者3件は `docs/ai-instructions.md` が定める docs/CLAUDE.md/Copilot の
  3点セット同期からの逸脱だった。
- **`docs/ai-instructions.md` に Copilot CLI のセッション再読込に関する制約を追記**:
  「チャットは日本語で応答」ルールは文言一致で反映済みだったが Copilot CLI で効かない
  事象があり、調査の結果 Copilot CLI はアクティブなセッション中は指示ファイルの変更を
  再読込しない（新規セッション開始まで反映されない）という制約を確認した。個人用の
  `$HOME/.copilot/copilot-instructions.md` の存在とあわせて「既知の制約」に記録。

## [0.3.2] - 2026-07-12

### Added


- **issue テンプレートの公開判断をファイル単位に変更**: `.github/ISSUE_TEMPLATE/`
  全体を丸ごと除外していたが、ファイル単位の除外に変更。`bug-report.md`/`chore.md`/
  `feature-sdd.md`/`verification.md`はいずれも運用検証中のため引き続き除外。
  `config.yml`はテンプレート個別の内容に依存しない（`blank_issues_enabled`のみ）ため
  公開対象。
- **実機E2Eスモーク（第4のゲート）を `cd-app.yml`（main/本番）にも展開**（#376 PR③、PR #385）:
  sandboxで実機検証済みの post-deploy smoke-test ジョブを、`deploy-api`/`frontend` 成功後の
  ジョブとして `cd-app.yml` に追加。`cd-app-sandbox.yml` と同じ per-run 使い捨て Cognito
  ユーザー方式だが、失敗時に run URL・デプロイ SHA・失敗ステップ（S1/S2/S3、Playwright JSON
  reporter を `jq` で解析）を含む issue を `e2e-live` ラベルで自動起票する点が異なる
  （「バグは直す前に issue 化」運用のワークフローへの埋め込み）。ジョブはリポジトリ変数
  `LIVE_SMOKE_ENABLED` を `true` に設定するまで実行されない**デフォルト無効のオプトイン**
  （`BACKEND_ENABLED`/`FRONTEND_ENABLED` 等のエリア別スイッチとは逆の極性）: 本番の Cognito
  User Pool に対して実際に Admin ユーザー作成/削除を行う新しいブロッキングゲートのため、
  `infra/bootstrap/` の `ci_deploy_auth`（Cognito 管理権限、人力適用）が反映され動作確認が
  済むまでは、無条件で `main` デプロイをブロックしないようにするための安全策。
- **`cd-infra.yml` の `apply` に `INFRA_APPLY_ENABLED` によるオプトインの二重ゲートを追加**:
  `apply` は既に `workflow_dispatch` 限定・`main` ブランチ限定（#301）だったが、これに加えて
  リポジトリ変数 `INFRA_APPLY_ENABLED` を `true` に設定しない限り実行されないようにした
  （`workflow_dispatch` 権限と変数編集権限という別々の鍵が両方必要になる）。`LIVE_SMOKE_ENABLED`
  と同じくデフォルト無効のオプトイン。`ci.yml` の infra 静的チェックと `cd-infra.yml` の
  `plan` は AWS へ変更を加えないため対象外とし、既存の `INFRA_ENABLED`（デフォルト有効）の
  ままにした。

### Changed

- **実機E2Eスモークを Playwright `live-smoke` プロジェクトへ昇格**（#376 PR①、PR #383）:
  #373の生スクリプト（`chromium.launch()` を直接叩き、trace/screenshot/video等の診断機能を
  持たない）を、既存の `npm run test:e2e` と同じ Playwright Test runner ベースの `live-smoke`
  プロジェクトに置き換え。Cognito Hosted UI ログイン〜アクセストークン取得を `accessToken`
  fixture 化（アプリが `InMemoryWebStorage` にしかトークンを保持しないため、OAuth2トークン
  交換レスポンスを直接キャプチャ）。S1（ログイン）/S2（書き込みAPI）/S3（別セッションでの
  整合性確認）を `test.step()` で構造化し、`trace: 'on'` / `screenshot: 'on'` / `video: 'on'`
  を常時有効化。設計判断は [ADR-0008](docs/adr/0008-live-smoke-playwright-project-with-disposable-cognito-user.md)
  に記録。

- **`cd-infra-sandbox.yml` に `workflow_dispatch` 経由の teardown（destroy）を追加**:
  `docs/sandbox.md` は sandbox を「使い捨ての隔離環境」と定義していたが、`apply` のみで
  自動化された削除手段が無かった（ローカルで人力 `terraform destroy` する手順のみ
  記載）。`confirm_destroy` 入力に文字列 `destroy` を入力したときだけ `destroy` ジョブが
  走るオプトイン方式（誤操作防止。`apply` は引き続き push 限定で `workflow_dispatch` からは
  実行されない）。OIDC 経由（長期キー不要）。`docs/sandbox.md` に手順を追記。
- **sandbox デプロイの live-smoke 組み込みとテストユーザー使い捨て化**（#376 PR②、PR #384）:
  固定の事前登録済みCognitoユーザー方式（#373）を、per-run 使い捨てユーザー
  （`AdminCreateUser`/`AdminSetUserPassword` で作成しパスワードは非保存、`if: always()` で
  `AdminDeleteUser`）へ置き換え、sandbox の `smoke-test` ジョブを `live-smoke` プロジェクト
  実行に全面書き換え。`ci_deploy_auth` に `cognito-idp:Admin*`（対象は user pool ARN に限定）を
  追加。置き換え済みの `services/frontend/scripts/smoke-test-sandbox.mjs` は削除。
  `infra/bootstrap/` は CI 外・人力適用の層のため、実 AWS への反映には手動 `terraform apply`
  が必要（未実施の間は sandbox の smoke-test ジョブが権限不足で失敗するか、警告付きスキップの
  まま）。
- **sandbox 関連リソースをゴールデンパスの一部として公開ミラー対象に変更**:
  `ci-sandbox.yml` / `cd-infra-sandbox.yml` / `cd-app-sandbox.yml` / `sandbox-guard.yml` /
  `docs/sandbox.md` / `infra/env/sandbox.*.example` を
  `tools/script/publish-to-public.sh` の `EXCLUDES` から外した。sandbox（実AWSでの
  使い捨て検証・アプリ開発フロー）は fork した人にも汎用的に有用と判断したため。
  `golden-path-verify`（テンプレート自体を毎回ゼロから検証する自己検証専用ツール）とは役割が
  異なり、開発用リポジトリ限定の扱いとして引き続き公開対象外。
  2bの参照クリーンアップ処理から`sandbox`を対象外にし（`release`のみに縮小）、
  今は死んでいた`CLAUDE.md`の`## Sandbox branches`セクション除去ロジック（該当見出しが
  既に存在せず no-op だった）も削除した。`docs/release.md`・`docs/sandbox.md`・
  `docs/infrastructure.md`・`docs/README.md`の「公開対象外」表記を修正。


### Fixed

- **`cd-app.yml`（main）が `cd-app-sandbox.yml` と同一のAWSリソースを共有し、
  `migrate` ジョブが連続失敗していた問題を修正**（#392）: 両ワークフローが同名の
  リポジトリ変数（`ECS_CLUSTER`/`WEB_BUCKET`等）を参照しており、本番用の別インフラが
  存在しない状態でも `cd-app.yml` の `preflight` が「設定済み」と誤判定し、sandbox用の
  リソースへデプロイを試みていた。`sandbox/order-management` ブランチのAlembic
  マイグレーションが `main` の知らないリビジョンまで共有DBを進めてしまい、`migrate`
  ジョブが `exit code 255` で連続失敗する実害が出ていた。`cd-app-sandbox.yml` のリソース
  識別子の変数を `SANDBOX_` プレフィックス付きで登録・参照するよう変更し、`cd-app.yml`
  側はプレフィックスなしの変数名を読んだまま据え置いた。本番用インフラが存在しない間は
  `cd-app.yml` の `preflight` が正しく「未設定」を検知してスキップするようになる
  （本番インフラを実際にプロビジョニングした際は、プレフィックスなしの変数名でその出力を
  登録するだけでワークフロー変更なしに有効化される）。
  > 当初は GitHub Environments（`environment: sandbox`）でのスコープ分離を実装したが
  > （直後にマージ、`sandbox/order-management` へ反映した時点で発覚）、`environment:`
  > を宣言したジョブは OIDC トークンの `sub` クレームが
  > `repo:<org>/<repo>:ref:refs/heads/sandbox/*` から
  > `repo:<org>/<repo>:environment:sandbox` に変わり、`infra/bootstrap` の deploy
  > ロール信頼ポリシーがこの組み合わせを許可していないため `AssumeRoleWithWebIdentity`
  > が失敗し、稼働中の sandbox デプロイを壊した。IAM 変更（人力の `terraform apply`）
  > なしで直せるプレフィックス方式に即座に切り替えた。

## [0.3.1] - 2026-07-11

### Fixed

- **公開リポジトリ（iwata-jawsug-jp/devcon）の Code scanning が検出した不完全なURLサニタイズ
  を解消**（PR #381）: `services/frontend/scripts/smoke-test-sandbox.mjs` の Cognito Hosted UI
  リダイレクト判定が `page.url().includes('amazoncognito.com')` という文字列部分一致
  チェックで、`https://evil.example/amazoncognito.com` のようなURLも通してしまう不完全な
  サニタイズだった（CodeQL `js/incomplete-url-substring-sanitization`）。
  `new URL(url).hostname.endsWith('.amazoncognito.com')` によるホスト名検証に修正。

## [0.3.0] - 2026-07-11

### Added

- **issueテンプレート一式**（#362 / #363）: SDD入力用（`feature-sdd.md`）・バグ報告・雑務タスクの
  3種、および検証issue用テンプレート（発見→記録→分割→検証→クローズのループを起票時点で強制）を
  `.github/ISSUE_TEMPLATE/` に整備。開発用リポジトリで運用検証中の扱いのため、公開ミラー
  （iwata-jawsug-jp/devcon）には含めない。
- **デプロイ後の実ブラウザE2Eスモークテスト**（#373 / PR #377）: `cd-app-sandbox.yml` に
  `smoke-test` ジョブを追加。Playwright（headless Chromium）で実際に Cognito Hosted UI
  ログインを完走させ、認証付き `GET /api/items` が2xxを返すことを確認する「第4のゲート」。
  CIロールがCognitoユーザー管理権限を持たないため、人が事前に1回だけ登録した固定テスト
  ユーザーを再利用する方式。関連変数が未設定なら fail ではなく warning 付きでスキップする。
- **Cognito設定が未注入のまま起動した場合の早期警告**（#375 / PR #379）: バックエンドは起動時に
  `cognito_user_pool_id`/`cognito_client_id` が空なら `logger.warning`、フロントエンドは
  `oidcConfig.ts` 読み込み時に `VITE_COGNITO_*` が空なら `console.warn`。いずれも起動/ビルド
  自体は止めず、CloudWatch Logs/ブラウザコンソールで設定漏れを早期検知できるようにする。

### Fixed

- **order-management golden path 実機E2E検証（#364）で発見された、実デプロイ環境限定の認証
  まわりの欠陥を一括解消**（#365 / #367 / #369）:
  - CloudFront の CSP（`connect-src`）が `oidc-client-ts` の Cognito への cross-origin fetch
    をブロックしていた（PR #366）
  - `cd-app(-sandbox).yml` の frontend ビルドステップが `VITE_COGNITO_*` を一切注入しておらず、
    authority URL が不正な形になっていた（PR #368）
  - ALB ターゲットグループのヘルスチェックポートが `traffic-port`（未指定）のままだった
    （PR #370。事象の切り分けとして先行対応、根本原因は別）
  - プライベートサブネットに `cognito-idp` 用 VPC インターフェースエンドポイントが無く、
    JWKS取得の経路が存在しないため認証付きリクエストが504になっていた（PR #371、真の
    根本原因）
  - ECS タスク定義に `API_COGNITO_*` 環境変数が一切注入されておらず、JWKS取得が直っても
    トークン検証が常に失敗していた（PR #372）
- **`container_image` 未指定時に存在しない `:bootstrap` タグへフォールバックし、インフラ専用の
  `terraform apply` のたびに ECS デプロイが `CannotPullContainerError` で失敗する構造的な欠陥
  を解消**（#374 / PR #378）。`data "external"` で現在実際にデプロイ済みのイメージタグを読み取り、
  それを既定値にする方式に変更。sandbox実機で infra-only な apply が正常に image を引き継ぐこと
  を検証済み。

## [0.2.10] - 2026-07-09

### Changed

- **frontend 依存パッケージの最新化**（#358 / PR #359）: ESLint 10 系へメジャー更新
  （eslint 10.6.0 / @eslint/js 10.0.1 / eslint-plugin-vue 10.9.2 / globals 17.7.0。
  flat config 移行済みのためコード修正なし）。`@types/node` はランタイム（CI /
  Dev Container / engines すべて Node 24）に整合する `^24.13.3` を採用し、latest の
  26 系は不採用。あわせて vitest 4.1.10 / vite 8.1.4 / prettier 3.9.5 に更新。
- **dependabot PR 9 件を検証のうえ一括採用**（#360）: `sandbox/dependabot` ブランチに
  結合して CI (sandbox) green を確認してからマージ。
  - frontend: vue-tsc 2.2.12 → 3.3.7（TypeScript 5.9.3 との組合せで全ゲート検証済み）
  - backend: uvicorn `>=0.51.0` / mypy 2.2.0
  - infra: AWS provider 6.53.0 → 6.54.0（lock 2 面）
  - GitHub Actions のメジャー更新: actions/cache v6・actions/setup-python v6・
    setup-tflint v6・docker/setup-buildx-action v4・aws-actions/configure-aws-credentials
    v6。主な破壊的変更はいずれも Node 24 ランタイム化（要 runner v2.327.1+、GitHub
    ホストランナーでは影響なし）。認証クリティカルな configure-aws-credentials@v6 は
    CD Infra (sandbox) で実 AWS への OIDC 認証成功を実機確認済み

> **検証の結果、意図的に見送った更新**（#358 の検証記録参照）:
>
> - **TypeScript 7.0.2**: TS 7.0 は JS プログラマティック API を同梱せず、vue-tsc /
>   typescript-eslint / openapi-typescript が起動不能。公式互換パッケージ
>   `@typescript/typescript6` の alias 構成も Volar の tsc パッチ機構と非互換で Vue では
>   使えないことを実測確認。`^5.5.0` を維持し、TS 7.1 の新 API → typescript-eslint 対応
>   → vuejs/language-tools#5381（tsgo 対応）が揃ってから再検討。なお TS 6.0.3 + TS7 併存
>   構成（`baseUrl` 削除 + overrides 込み）で全ゲート green になることは実証済みで、
>   必要になれば移行可能。
> - **@unhead/vue 3**: vite-ssg 28.3.0（最新）が v2 を通常依存として同梱するため、root
>   だけ v3 に上げると二重インスタンス化し、**全ゲート green のまま** SSG 出力の
>   `<head>`（titleTemplate / description / OG / theme-color）が静かに欠落することを
>   実測確認。vite-ssg の unhead v3 対応まで見送り。@types/node 26 とともに dependabot
>   へ `ignore this major version` を設定済み（解禁時はクローズ済み PR #354 / #357 で
>   `unignore` する）。

## [0.2.9] - 2026-07-07

### Added

- **CI/CD のエリア別スイッチ**: リポジトリ変数 `BACKEND_ENABLED` / `FRONTEND_ENABLED` /
  `INFRA_ENABLED` で、frontend / backend / infra ごとに CI・CD ワークフローの実行可否を
  切り替えられるようにした（PR #343）。GitHub Actions の `on:` トリガーでは `vars` を
  参照できないため、ジョブレベルの `if`（`vars.X != 'false'`）でゲートする方式。
  **未設定はデフォルト有効**なので、変数を登録しない限り挙動は従来どおり（公開ミラー・
  fork も不変）。`cd-infra.yml` の apply は手動 `workflow_dispatch` でもスイッチが効く。
  設定手順・注意事項（スキップされたジョブは required status check として合格扱いに
  なる等）は [docs/ci-cd-area-switches.md](docs/ci-cd-area-switches.md) を参照。

## [0.2.8] - 2026-07-07

### Fixed

- **`ci_deploy`ロールの権限不足・無効ステートメントを実機検証で洗い出して解消**（#258 /
  #334 / #338）。sandbox 実機での apply→destroy フルライフサイクル検証により、静的分析
  （PR #107）では検出できなかった以下を修正:
  - RDS が呼び出し元の代わりに行う KMS 操作の権限が皆無で、暗号化 RDS インスタンス作成が
    `KMSKeyNotAccessibleFault` で失敗していた。デフォルト AWS 管理キー（`alias/aws/rds`・
    `alias/aws/secretsmanager`）への `kms:DescribeKey` と、rds キーへの `kms:CreateGrant` を
    追加（#334）
  - `manage_master_user_password = true` でのマスターシークレット作成に必要な
    `secretsmanager:CreateSecret`/`TagResource`（`rds!*` スコープ）を追加（#334）
  - `EcsTaskDefinitions` ステートメントが**実在しない条件キー** `ecs:task-definition-family`
    により無言で無効化されており、`ecs:RegisterTaskDefinition` が AccessDenied になっていた。
    task-definition ARN スコープへ修正し、`default_tags` が作成時に評価する
    `ecs:TagResource` も追加（#338）
  - `ecs:RunTask` が task-definition リソースタイプに対して評価されるのに cluster 等の ARN
    にしか許可されておらず、一度もマッチし得ない無効グラントだった問題を task-definition
    ARN スコープのステートメントへ移動（PR #339 レビューで発見）
  - destroy 時に provider が `DeleteRole` の前に必ず呼ぶ `iam:ListInstanceProfilesForRole`
    が不足しており、IAM ロール削除が失敗していた（PR #341）

### Security

- **`ci_deploy` の KMS/ECS 権限を CloudTrail 証跡ベースの最小構成にトリム**: どの実機 run
  でも行使されなかった `kms:ListGrants`・`ecs:ListTaskDefinitions`・`ecs:UntagResource`・
  `ecs:ListTagsForResource` を削除し、`kms:CreateGrant` に
  `kms:GrantIsForAWSResource = true` 条件を付与（AWS サービス経由の grant 作成に限定）。

> この一連の検証により `ci_deploy` ロールの apply→destroy フルライフサイクルが最小権限で
> 実機検証済みとなり、#45 / #258 は完了。フォローアップとして、実在しない条件キーを CI で
> 静的検出するゲートの追加を #340 で追跡する。

## [0.2.7] - 2026-07-06

### Added

- **複数フレームワーク比較デモの構成案**: 学習・比較目的で複数フロントエンドフレームワーク
  実装を並べるための構成案を `docs/frontend-frameworks-demo.md` に追加。本番の
  `services/frontend/`（Vue 3）は変更せず、`sandbox/ec-site-demo` と同じブランチ分離方式
  （sandbox ブランチ内 `demos/frontend-frameworks/<framework>/`）を踏襲する方針を記録。

### Changed

- **モノレポ評価レポート（#153）の低優先度指摘を解消**（#306）:
  - backend バージョンの三重不一致を解消（`__init__.py` を `pyproject.toml` に合わせた）
  - `GET /api/items` に `limit`（既定 50・上限 100）/`offset` によるページネーションを追加
  - ruff に `S`（bandit 相当）ルールを追加（Cognito の `token_use` クレーム値を誤検知した
    3 件は `# noqa` + 理由コメントで対応）
  - frontend のカバレッジ閾値を実測値に合わせて引き上げ（`35/35/45/55` → `90/90/90/80`）
  - `index.html` の `lang="en"` と日本語コンテンツの不一致を `lang="ja"` に修正（vite-ssg の
    SSR レンダリングが `htmlAttrs` 未指定だと上書きする問題を含む）
  - プレースホルダ `<h1>web</h1>` を `devcon` に変更
  - `ci.yml` に Playwright ブラウザバイナリのキャッシュ、`cd-app.yml`/`cd-app-sandbox.yml`
    を buildx + GitHub Actions キャッシュに変更
  - `cd-infra.yml` の plan コメントを隠しマーカーで検索し、既存コメントを更新するよう変更
    （sticky 化）
  - VPC エンドポイント（ECR api/dkr・Logs・Secrets Manager・xray）を dev/sandbox のみ
    単一 AZ 化し、固定費を削減（`var.vpce_single_az`）
  - sandbox/prod で deploy role を分離しない現状維持を決定し、実際の環境隔離が
    sandbox-guard と `TF_ENV` 固定に依存している実態を `docs/infrastructure.md` に明記
  - `.env.example` に不足していた component-based DB 設定・分散トレーシング関連の変数を追記
- **`metrics-dora.yml`/`perf.yml` の `schedule`（cron）トリガーを削除し `workflow_dispatch` 限定に
  変更**: この monorepo は学習・デモ目的で実トラフィックがなく、定期実行しても意味のあるデータが
  貯まらないため。本番運用のアプリで再有効化する手順を `docs/infrastructure.md` に「アプリ開発時の
  初期設定事項」として追記。


### Security

- **`cd-infra.yml` の prod apply が main 以外のブランチからの `workflow_dispatch` でも
  実行できた問題を修正**（#301）: deploy ロールの OIDC 信頼条件が `environment:production`
  の宣言だけで満たされてしまうため、job の `if` に `github.ref == 'refs/heads/main'` を
  追加し、main 以外からの手動実行は skip されるようにした。
- **items API の入力長が無制限で、認証済みユーザーによる DB ストレージ圧迫を防げない
  問題を修正**（#305）: `name`（上限 200 文字）/`description`（上限 2000 文字）を追加。
- **`ci_deploy` ロールの実機検証（#258, #45 follow-up）で判明した不足権限を順次追加**:
  sandbox 環境での `terraform apply` 実機検証により、以下の権限不足が判明・修正した
  （**検証は継続中で、本項目は今後の PR で更新される見込み**）。
  - Cognito（#41）・SNS/CloudWatch アラーム・ダッシュボード（#42）がポリシーに
    一切含まれていなかった
  - VPC エンドポイント作成・RDS サブネットグループ操作関連の `ec2:DescribePrefixLists`/
    `DescribeNetworkInterfaces`、`rds:AddTagsToResource` 等で `subgrp:` リソースへの
    スコープが漏れていた
  - インラインポリシーがロール全体で共有する 10,240 バイト上限を超過したため、8 本すべてを
    カスタマー管理ポリシー（`aws_iam_policy` + `aws_iam_role_policy_attachment`）に変更
  - S3 バケットの付随設定読み取り系（Acl/CORS/Website/Logging 等）が不足していた
  - Cognito MFA 設定の読み取り、RDS `CreateDBInstance` の `subgrp:` リソースへの
    スコープ漏れを追加

### Fixed

- **ECS `api` サービスがデプロイ失敗時に自動ロールバックしない問題を修正**（#302）:
  `deployment_circuit_breaker`（`enable = true, rollback = true`）を追加。
- **ECR のタグ付きイメージ・S3 の非現行バージョンが無期限に蓄積する問題を修正**（#303）:
  lifecycle policy を追加（ECR は直近 30 世代、S3 state バケットは 90 日、web バケットは
  30 日で expire）。state バケット側の変更は `infra/bootstrap/` 層のため、実 AWS への反映
  には手動 `terraform apply` が必要。
- **未捕捉の例外が FastAPI デフォルトの素の 500 を返し、`X-Request-ID` も欠落する問題を
  修正**（#304）: 構造化 JSON レスポンス（`{"detail": ..., "request_id": ...}`）を返す
  `exception_handler` を追加。frontend にも構造化エラー型 `ApiError` と、クエリキャンセル
  時に実際の `fetch` を中断する `AbortSignal` 伝搬を追加。

## [0.2.6] - 2026-07-05

### Fixed

- **公開リポジトリの GitHub Code Quality 指摘（maintainability, note）を解消**:
  - `.github/scripts/tests/test_dora_metrics.py`: `unittest` を `import` と
    `from unittest import mock` の両方でインポートしていた（`py/import-and-import-from`）ため、
    `import unittest.mock` に統一。
  - `services/backend/python/alembic/` の `revision`/`down_revision`/`branch_labels`/
    `depends_on`（Alembic が実行時にモジュール属性として動的参照するため実際には必要）が
    `py/unused-global-variable` として検出されていた。CodeQL のルール説明が明記する
    `__all__` による意図的な公開の明示で解消。既存マイグレーション（`0001_create_items.py`）
    と、今後生成されるマイグレーションに効くよう `script.py.mako` テンプレートにも追加。
  - 残り1件（`alembic/env.py` の `models` 副作用インポート、`py/unused-import`）は
    Alembic の autogenerate に必要なインポートで削除できないため、公開リポジトリ側で
    false positive として dismiss 対応（コード変更なし）。
- **README.md の Release バッジが動作しない問題**: 公開用リポジトリ（`iwata-jawsug-jp/devcon`）は
  `publish-to-public.sh` の deploy key が git push 専用のため GitHub Release オブジェクトを作らず、
  タグのみ更新される。そのため shields.io の `github/v/release` バッジ（Releases API 参照）は
  「no releases found」と表示されていた。タグを参照する `github/v/tag` バッジに変更。

### Added

- **README.md に Security Policy バッジを追加**: `SECURITY.md`（#293）へリンクする静的バッジ。

## [0.2.5] - 2026-07-05

### Security

- **frontend の開発用依存関係にある Dependabot アラート対応**: `@lhci/cli`（Lighthouse CI、
  開発時のみ使用でプロダクションビルドには含まれない）が要求する `tmp@^0.1.0` /
  `uuid@^8.3.1` の範囲がパッチ済みバージョンを含まず、Dependabot が
  [`tmp` の Path Traversal（CVE-2026-44705, High）](https://github.com/iwata-jawsug-jp/devcon/security/dependabot/3)、
  [`uuid` のバッファ境界チェック漏れ（CVE-2026-41907, Medium）](https://github.com/iwata-jawsug-jp/devcon/security/dependabot/2)、
  [`tmp` のシンボリックリンク経由の任意ファイル書き込み（CVE-2025-54798, Low）](https://github.com/iwata-jawsug-jp/devcon/security/dependabot/1)
  を検知していた。`package.json` の `overrides` で `tmp@^0.2.6` / `uuid@^11.1.1` に強制固定し、
  `npm audit` の指摘を解消（lint/typecheck/test/`lhci healthcheck` で動作確認済み）。

## [0.2.4] - 2026-07-05

### Added

- **SECURITY.md**: 公開用リポジトリ（`iwata-jawsug-jp/devcon`）向けに脆弱性報告ポリシーを追加。
  GitHub の Private Vulnerability Reporting 経由での報告を案内する


## [0.2.3] - 2026-07-05


### Changed

- **チャット応答の既定言語を明記**（#289）: `CLAUDE.md`／`.github/copilot-instructions.md` に、
  対話の応答は原則日本語である旨を追記。成果物（コード・コミットメッセージ・PR/issue 本文等）
  の言語運用は変更しない。

## [0.2.2] - 2026-07-05

### Added

- **認証・認可（Cognito/JWT）の導入**（#41, Epic #46）: Cognito Hosted UI + JWT による
  認証・認可を追加。Terraform で User Pool・Resource Server（`api/items.read`/
  `api/items.write` スコープ）・パブリッククライアント（PKCE）を構築し、backend は
  `get_current_user`（JWT 署名/exp/iss/token_use/client_id 検証）と `require_scope`、
  frontend は `oidc-client-ts` ベースの `AuthStore`（トークンはメモリ限定保持）・
  ログイン/コールバック画面・ルーターガード・401 時の 1 回限りのリフレッシュ＋再試行を実装。
  既存 `items` ルーターに GET=読み取り/POST=書き込みスコープを適用。read/write を超える
  ロール・所有者ベース認可（→ #40）、WAF・レート制限（→ #44）、MFA 等はスコープ外として
  次の issue へ切り出し。
  - `.env.example` への Cognito サンプル値追記（#255）。
- **可観測性の整備**（Epic #42）: メトリクス・ダッシュボード・アラーム・トレース・SLO を
  一式追加。
  - **構造化ログ＋リクエスト相関 ID**（backend のみ）: JSON 1 行ログ（`JsonFormatter`）と、
    `X-Request-ID` を引き継ぐ/生成する `CorrelationIdMiddleware` を追加。
  - **分散トレーシング**: OpenTelemetry 計装＋ ADOT コレクタサイドカー→ AWS X-Ray を採用
    （ADR-0007）。`API_OTEL_TRACES_ENABLED`（dev 既定 false・prod 既定 true）で有効化し、
    無効時は追加コスト 0。JSON ログにも `trace_id`/`span_id` を付与。
  - **CloudWatch アラーム＋ SNS 通知**: ALB 5xx/レイテンシ、ECS CPU/メモリ、RDS CPU/
    接続数/空き容量の 7 アラームをメール通知（`alert_email` 未設定なら購読自体を作らない）。
  - **CloudWatch ダッシュボード**: 上記と同じ指標を 1 枚にまとめ、
    `terraform output cloudwatch_dashboard_url` で確認できる出力を追加。
  - **ヘルスチェックの DB 疎通確認＋ SLO/SLI 方針**: `GET /api/health` が `SELECT 1` で
    DB 疎通を確認し、失敗時は 503 を返すよう修正（従来は DB 全断でも 200 を返していた）。
    SLI（可用性＝ ALB 2XX 比率、レイテンシ＝ p95 TargetResponseTime）を
    `docs/infrastructure.md` に提案として記録。
- **負荷・性能テスト（k6）の導入**（#43）: `perf/k6/items-smoke.js` で health→list→get→
  create のシナリオを p95 レイテンシ・エラー率のしきい値で判定。毎週日曜＋手動実行のみで
  PR ごとには回さない。認証はスタブ化し、自前 API（ルーティング/バリデーション/DB 層）の
  性能に計測範囲を意図的に限定。
- **フロントエンドの DESIGN.md 仕様ビジュアルアイデンティティ文書**（#263）:
  `docs/frontend-design.md` を DESIGN.md 仕様（YAML トークン＋ prose）で追加し、既存の
  `brand-*` カラー・`font-sans` スタックから 1:1 で作成。
- **DESIGN.md からのテーマトークン自動生成**（#264）: `@google/design.md` を導入し、
  `docs/frontend-design.md` のトークンから `main.css` の `@theme` ブロックを生成する
  `make gen-design-tokens` を追加。`design:lint`（トークン整合性・WCAG コントラスト検証）を
  `make ci-frontend`/CI に組み込み。

### Security

- **deploy IAM ロールの権限をさらに縮小**（#45 follow-up）: `aws:RequestedRegion` 条件の
  追加（リージョン依存サービスのみ）、`elasticloadbalancing:*`/`application-autoscaling:*`/
  `cloudfront:*` の実使用アクションへの縮小、`iam:PassRole` を
  `iam:PassedToService=ecs-tasks.amazonaws.com` 条件付きの専用ステートメントへ分離。
  `infra/bootstrap/` は CI/CD 管理外のため、実 AWS への反映には人による手動
  `terraform apply` が必要。
- **plan ロールの state アクセスを dev キーのみに限定**（#45, #153）: `ci_plan` ロールが
  `ci_deploy` と同じ state バケット全体ポリシーを共有しており、PR を開くだけで理論上
  prod/sandbox の state ファイルを上書き・削除できた問題を修正。`ci_plan` 専用ポリシーを
  新設し、読み取りは dev 環境の state オブジェクトのみ、書き込みは dev のロックファイルのみに
  限定。
- **CloudFront オリジンを ALB でシークレットヘッダー検証**（#271）: ALB のセキュリティ
  グループは全 CloudFront ディストリビューションで共有される AWS 管理プレフィックス
  リストしか見ておらず、他人のディストリビューションからこの ALB へ直接到達できた問題を
  修正。CloudFront が `X-Origin-Verify` シークレットヘッダーを付与し、ALB リスナーは
  デフォルト拒否（403）＋ヘッダー一致時のみ転送するルールへ変更。

### Fixed

- **CI ツールのバージョン固定**（#272）: `setup-tflint`/`trivy-action`/checkov が
  `.devcontainer/Dockerfile` の固定バージョンと異なるバージョンで実行されていた問題を修正し、
  tflint 0.63.1 / trivy 0.71.2 / checkov 3.3.2 に統一。
- **frontend の生成型ドリフト**（#270）: `HealthResponse` が手書きのままで、生成済み
  `HealthStatus`（`database` フィールド追加済み）から乖離していた問題を修正。
- **mypy のスコープ不一致**（#269）: CI の `uv run mypy .` と `make backend-lint` の
  `mypy` が異なるファイル集合を検査していた（`alembic/` が CI のみ対象）問題を修正。

### Changed

- **`settings.local.json` がマージ確認ゲートを緩めうる点を明記**（#268）: `CLAUDE.md` の
  「main への無断マージ禁止」が permission 設定だけに依存するものではなく、標準的な運用
  ルールであることを明確化。


## [0.2.1] - 2026-07-04

### Added

- **DORAメトリクスの週次自動計測**（#237）: DORA Four Keysのうちデプロイ頻度・変更リード
  タイムを、追加インフラなしにGitHub Actions/GitHub APIのデータだけで自動集計する。
  - 計測定義（デプロイイベント・リードタイムの判定ロジック）をADR-0006として記録。
  - `.github/scripts/dora_metrics.py`（Python標準ライブラリのみ、単体テスト付き）で
    週次のデプロイ回数（backend/frontend/合算）とリードタイム（中央値・p85）を算出。
  - `.github/workflows/metrics-dora.yml` を `schedule`（週次）+ `workflow_dispatch`
    （任意期間指定）で実行し、job summaryへの出力と `docs/metrics/` への月次スナップ
    ショット追記を行う。`main` の必須ステータスチェックにより直接pushできないため、
    スナップショットはブランチpush + job summaryへのcompareリンク提示で、PRは手動で開く。
  - 直近4週間の移動平均をあわせて出力。
  - 公開用リポジトリへの変換公開時は `schedule` トリガーのみ除去する（継続的な自動実行は
    公開用には想定しないため）。
- **SDDの実装フェーズ運用規約**（#211, #212, #213）: 帳簿同期・design整合・非機能要件の
  所有について、実装フェーズ中の運用ルールを追加。
- **authn-authz spec の承認**: 認証・認可の要件・設計・タスクをspecとして追加し、現行の
  ディレクトリ構成に追従の上、tasksの承認を反映。

### Fixed

- **eslintとprettierの整形ルール衝突**（#214）: `eslint-config-prettier` を導入し、
  両ツールが競合する整形ルールを無効化。
- **`make ci-frontend` のLighthouse実行**（#215）: ローカルにChromeが無い環境向けに、
  LHCIの起動先をPlaywright同梱のchromiumへフォールバックする。



## [0.2.0] - 2026-07-02

### Added

- **PWA 化**（#80）: `vite-plugin-pwa` で Web App Manifest（プレースホルダーアイコン付き）と
  ビルド時生成の Service Worker を追加。`workbox` の precache 対象はビルド済み静的シェルのみで、
  `/api/*` の runtimeCaching はあえて未設定（認証導入時の他ユーザーデータ混入を避けるため）。
  Lighthouse の PWA カテゴリは upstream で削除済みのため、`e2e/pwa.spec.ts`
  （`vite preview` に対する Playwright）で manifest の妥当性と Service Worker の
  active 化を検証する。
- **ECS Application Auto Scaling**（#44）: api の ECS Fargate サービスに CPU / メモリの
  target tracking ポリシーを追加。dev はスケール実質無効（min=max=1）、prod は 1〜4 タスクで
  実際にスケールする（`env/{dev,prod}.tfvars.example`）。インフラ堅牢化（#44）の残りの項目
  （WAF・KMS CMK・秘密ローテーション・DR/バックアップ方針・環境昇格フロー）は別 PR で対応する。
- **frontend のビルド時静的生成（vite-ssg）+ SEO/OGP基盤**（#78）: `services/frontend` を
  `vite-ssg build` で全ルート prerender するように変更（cloaking なし、全ユーザーに同一の
  静的HTML）。`@unhead/vue` の `useHead()` でページ単位の title/meta/OGP/JSON-LD を宣言でき
  るようにし、`vite-ssg-sitemap` で `sitemap.xml`/`robots.txt` をビルド時自動生成する。
- **Dependabot 導入**（#113）: GitHub Actions / npm / uv / Terraform / devcontainer / Docker の
  6 ecosystem を weekly で自動更新（minor/patch はグループ化して PR 数を抑制）。Dependabot
  非対応の pre-commit rev は四半期ごとの手動 `pre-commit autoupdate` 運用を CONTRIBUTING.md に明記。
- **`make ci-frontend`**（#111）: CI の frontend ジョブ（eslint / vue-tsc / vitest / build /
  バンドル予算 / Lighthouse / e2e）をローカルで一発再現する集約ターゲット。
- **ADR-0005**（#116）: Dev Container の Docker 実行方式として docker-in-docker
  （`--privileged`）を docker-outside-of-docker と比較のうえ継続採用した決定を記録。
- **cd-app の preflight ゲート**（#145）: アプリ層のリポジトリ変数（`ECR_REPOSITORY` /
  `WEB_BUCKET` 等）が未登録の間はデプロイジョブを明示 skip し、インフラ未適用でも main の
  CD を green に保つ（変数登録で従来どおりフルデプロイ）。

### Security

- **deploy IAM ロールの最小権限化**（#45）: `infra/bootstrap/` の `ci_deploy` ロールから
  AWS 管理の `PowerUserAccess` を外し、`infra/*.tf` が実際に使うサービス（EC2ネットワーク/
  ECS/ECR/ELB/RDS/S3/CloudFront/CloudWatch Logs/Application Auto Scaling）ごとにスコープした
  inline policy に置き換えた。**`bootstrap/` は CI 管理外のため、ローカルで
  `terraform apply` するまで実環境には反映されない**。CloudTrail 等の実アクセス履歴ではなく
  静的なリソース種別分析から導出したため、適用後に `AccessDenied` が出ないか
  `cd-infra.yml`/`cd-app.yml` で確認すること。
- **trivy を三層すべてでブロッキング化**（#150）: CI の trivy-action に `exit-code: 1` を
  付与し、pre-commit フック・`make security` と挙動を統一。許容する既存 findings（6 種）は
  `.trivyignore` に理由付きで明示し、新規の HIGH/CRITICAL はどの層でも fail する。

### Fixed

- `infra/CLAUDE.md` と `.github/instructions/infra.instructions.md` が「`cd-infra.yml` は
  `production` 環境で main マージ時にゲートされる」という古い記述のままだった（実際は手動
  `workflow_dispatch` ゲート）。`docs/infrastructure.md`/`README.md` は既に修正済み（#101）
  だったが、この2ファイルは見落としていた。

### Changed

- **サービスディレクトリ改名**（#98, ADR-0004）: `services/api` → `services/backend/python`、
  `services/web` → `services/frontend` にリネーム。バックエンドは開発言語ごとにサブフォルダを
  分ける構成にし、将来 Python 以外の言語を追加できるようにした。Makefile ターゲット
  （`api-*`/`web-*` → `backend-*`/`frontend-*`）、CI/CD のパスフィルタ・Docker ビルド
  コンテキスト、`CLAUDE.md`、Copilot 用ミラーもあわせて追従。Python パッケージ内部名（`api`）
  と Terraform の AWS リソース論理名（`api`/`web`）は意図的に変更していない。
- **開発環境の再現性強化**（Epic #108）: Dev Container のツールを `ARG` でバージョン固定
  （Terraform は CI と同じ 1.13.0 に統一）（#109）、Python ランタイムを `.python-version`
  （3.14）に単一ソース化してローカル / CI / 本番イメージを揃え（#110）、`make setup` を
  postCreate で自動実行（#115）、`docs/development-environment.md` をフロントエンドの
  現状（Vite + Vue 3）に追従（#112）。
- **品質ゲート三層（pre-commit / Makefile / CI）の同期**（#111）: `make tf-lint` を CI と
  同一の `tflint --recursive --config` に統一（CI が root `.tflint.hcl` の AWS ルールセットを
  黙って無視していた問題も修正）、checkov は三層とも advisory（`--soft-fail` + 理由明記）に、
  trivy の severity を `HIGH,CRITICAL` に統一。
- **prettier フックの刷新**（#114, #127）: deprecated な mirrors-prettier（v4 alpha）を
  frontend の `node_modules/.bin/prettier` を直接使う local フックに置換し、バージョンを
  `package.json` に一元化。フック未通過だった既存 26 ファイルを一括整形し、cc-sdd 上流物
  （`.claude/skills/`・`.kiro/settings/templates/`）は整形対象外に。
  `services/frontend/.prettierignore` で生成物 `schema.ts` の整形を防止。
- **依存メジャー更新**（#147 ほか Dependabot 15 PR）: vite 8 / vitest 4（カバレッジ計測の
  AST 化に伴いテスト追加でゲート維持）/ vue-router 5 / pinia 3 / jsdom 29、GitHub Actions
  （checkout v7・setup-node v6・setup-uv v7・setup-terraform v4・paths-filter v4）、
  AWS provider 6（state が空のうちに更新）、Dev Container を Ubuntu 24.04 +
  docker-in-docker feature 4.0 に更新。

## [0.1.4] - 2026-07-01

### Added

- **カバレッジゲート** `api`（pytest-cov）・`web`（vitest）（#43）: CI にカバレッジ閾値のゲートを追加。
- **a11y CI ゲート**（#83）: `web` の e2e に axe-core によるアクセシビリティチェックを追加し、CI で有効化。
- **Lighthouse CI ＋ JS バンドルサイズ予算**（#84）: gzip 済み JS バンドルサイズの予算チェックと
  Lighthouse CI（3 回実行で単発ノイズを低減）を導入。閾値は `docs/`（#90）に記録。
- **CloudFront セキュリティヘッダー**（#79）: SPA 配信用 CloudFront にセキュリティヘッダーを追加。
  `sandbox/*` で実 AWS 適用を検証してからマージ。
- **TanStack Query 導入**（#82）: `services/web` にサーバー状態管理として `@tanstack/vue-query` を導入し、
  `HealthBadge` を移行。
- **Tailwind CSS ＋最小デザイントークン**（#81）: `@tailwindcss/vite` を導入し、ブランドカラー・フォント
  スタックのみを定義した最小トークンセットを追加。
- **ADR-0003**: #40（ドメイン機能拡充）・#41（認証・認可導入）を既存のモノレポ構成（`services/api` /
  `services/web` / `infra`）のまま吸収する決定を記録。
- **GitHub Copilot CLI 互換性ドキュメント**（#75, #76）: `.claude/skills` が Copilot CLI からも利用可能な
  ことを明記。
- **Web フロントエンドのサイトアーキテクチャ近代化 提案書**（#77）。

### Changed

- **`.devcontainer/Dockerfile`**: GitHub Copilot CLI（`@github/copilot`）へ切り替える場合の具体的な手順を
  TODO コメントとして記録（実行内容・ビルド結果への影響なし）。

## [0.1.3] - 2026-06-30

### Added

- **SDD（仕様駆動開発）ツールを導入**（Epic #66）: 上流工程（要件定義・基本設計）を成果物として
  残すため、cc-sdd を `--claude-skills` 方式で導入。`.claude/skills/kiro-*`（`/kiro-*` スキル）と
  `.kiro/`（settings / steering / 試験導入の spec `items-add-field`）を追加。提案書が前提にしていた
  `--claude`（commands）方式は cc-sdd v3.0.2 で非推奨化したため、推奨の skills 方式を採用（#60, #61）。
- **SDD 運用ドキュメント** `docs/sdd.md`（#62）: `/kiro-*` スキルの使い方・`.kiro/` 構成・
  `.kiro/specs/<feature>` → `docs/requirements|design/` への昇格手順・**cc-sdd に `CLAUDE.md` を
  所有させない保護ルール**・公開ミラー/gitignore 方針・四半期 OSS 点検を明文化。
- **ADR（Architecture Decision Record）運用を開始** `docs/adr/`（#63）: ADR-0001（運用方針）＋
  テンプレート。インフラ・アーキ上の重要判断を「なぜそう決めたか」で記録。SDD 採用の判断は
  ADR-0002 として記録（#62）。
- **基本設計の図表方針** `docs/design/`（#65）: Mermaid を既定とし、精密な AWS 構成図は Python
  `diagrams` / draw.io を補助に使う方針と、`.drawio.svg` の round-trip 注意を文書化。
- **確定要件の保管庫** `docs/requirements/`（#62）: リリース済み機能の要件を `.kiro/specs/` から
  昇格して置く場所。

### Changed

- **`CONTRIBUTING.md` に SDD 適用基準を追記**（#64）: 粒度の大きい新機能は `.kiro/specs/` で要件定義
  →基本設計→タスク分解を経てから実装、単一の小機能は `/kiro-spec-quick`、軽微な修正は Plan Mode
  （`/plan`）で十分、という線引き（過剰適用＝「Waterfall の逆襲」を回避）。
- **`CLAUDE.md` / `docs/README.md` / `docs/ai-instructions.md`**（#62, #63, #65）: 上記の新ドキュメント
  （`docs/sdd.md` / `docs/adr/` / `docs/design/`）への参照を追加。SDD 成果物（`.kiro/`）は「何を作るか」、
  実装規約（`CLAUDE.md` / Copilot instructions）は「どう書くか」と役割が異なるため、`.kiro/` を Copilot
  ミラーの対象外とすることを明記。

## [0.1.2] - 2026-06-30

### Added


## [0.1.1] - 2026-06-29

### Changed

- **README を再編**（#57）: 「概要 / クイックスタート（ローカル）/ 本格セットアップ（自分の
  AWS で実開発）/ リファレンス」の 4 ブロック構成へ。ローカル開発（AWS 不要）と本格セットアップ
  （AWS 必要）を明確に分離し、公開リポジトリを fork して実開発を始めるまでの導線を追加。新サブ
  セクション「自分の AWS にデプロイする」で、`infra/bootstrap/` の `github_org` / `github_repo`
  を自分の fork に差し替える点（OIDC trust がリポジトリ限定のため）と リポジトリ変数 3 つの登録
  を要約（実体は `docs/infrastructure.md` を参照）。fork 手順は `<your-org>/<your-repo>` の
  プレースホルダで記述し、公開ミラー変換の整合を保つ。

## [0.1.0] - 2026-06-29

### Added

- **GitHub Copilot ルール化**（#54）: 既存の `CLAUDE.md` 群のガードレールを Copilot
  （IDE Chat / coding agent / code review）にも効かせるため、Copilot ネイティブの指示
  ファイルを追加。リポジトリ全体ルールの `.github/copilot-instructions.md` と、ネスト
  `CLAUDE.md` を `applyTo` グロブで 1:1 ミラーする `.github/instructions/` 配下の
  backend / frontend / infra 各 `*.instructions.md`。詳細は `docs/` 参照型の薄い抽出に
  留め、`CLAUDE.md` と同じ英語で記述してドリフト検出を容易にした。
- **AI 開発ルールの同期手順** `docs/ai-instructions.md`: ルールの「正」を `docs/` に一本化し、
  `docs/` ＋ `CLAUDE.md` ＋ Copilot 用ファイルを 1 PR でまとめて変更する運用を明文化
  （ファイル対応表・ドリフト点検・既知の制約）。`docs/README.md` とルート `CLAUDE.md` から参照。
- README に CI / Release バッジを追加（#53）。

## [0.0.6] - 2026-06-29

### Changed

- **`CLAUDE.md` を最適化**（毎セッション常時ロードの軽量化, #47）: ルートを高シグナルな
  ~50 行に圧縮し、落とし穴を `## Critical rules` として前方集約。領域固有の規約は
  path-scoped な nested `CLAUDE.md`（`services/api/` / `services/web/` / `infra/`）へ降ろし、
  そのサブツリーを触ったときだけ on-demand ロードする構成に。詳細は `@` なしのプレーン参照
  （`docs/app-development.md` / `docs/infrastructure.md` / `docs/sandbox.md`）へ委譲。重複
  （raw SQL 禁止 / Alembic 必須 / `vue-tsc` / `make gen-types`）を各 1 箇所へ集約。
- Working from issues フローを `docs/issues.md` として新規切り出し（ルートから参照）。
- **`cd-infra.yml`**: `backend.hcl` / `*.tfvars` を git-ignored の `.example` から CI 実行時に
  生成する方式へ（state バケット名はリポジトリ変数 `AWS_TF_STATE_BUCKET` で注入。秘密値は
  git・ログに出さず、`*.example` のみコミットの方針を維持）。bootstrap 適用後に PR の
  `terraform plan` が CI で通るようになった（#49, #50）。
- **apply の承認ゲート変更**: private リポジトリ＋現プランでは GitHub Environment の
  required reviewers が使えないため、`apply` を main push 自動実行から手動
  `workflow_dispatch` に変更（`push: main` トリガー削除）。マージで prod が自動 provision
  されず、手動実行そのものをゲートとする。恒久化手順（Enterprise / Team / Pro 移行・
  public 化）は `docs/infrastructure.md` に追記（#50, #51）。

### Fixed

- **CI（cd-infra）**: OIDC のロール ARN / state バケット名が未登録のため `plan` / `apply` が
  認証・`init` 段階で失敗していた問題を、`infra/bootstrap/` 適用＋リポジトリ変数
  （`AWS_PLAN_ROLE_ARN` / `AWS_DEPLOY_ROLE_ARN` / `AWS_TF_STATE_BUCKET`）の登録で解消（#49）。

## [0.0.5] - 2026-06-27

### Added

- **アプリ実行基盤**（`infra/`）: **ECS Fargate + ALB**（CloudFront 経由で `/api/*`）、
  **VPC エンドポイント**（ECR/logs/secretsmanager + S3 gateway、NAT なしで private タスクが
  pull/secret 取得）、**CloudFront + OAC**（default→S3 SPA, `/api/*`→ALB, SPA エラー応答）、
  ECS 実行/タスク IAM ロール、api タスク定義（DB を env + Secrets Manager 注入）。3 層アプリを
  実 AWS にデプロイ可能化。
- **sandbox 開発環境**: `sandbox/*` 隔離ブランチで CI/CD を実 AWS 検証。専用ワークフロー
  `ci-sandbox.yml` / `cd-infra-sandbox.yml` / `cd-app-sandbox.yml`（`push:[sandbox/**]`）、
  `sandbox-guard.yml` + GitHub ルールセットで **`sandbox/*` → 非 sandbox のマージを禁止**、
  `env/sandbox.*.example`、`docs/sandbox.md`。sandbox 関連リソースは公開ミラー対象外。
- bootstrap の deploy ロールに **プロジェクト限定の IAM 管理権限**（ECS ロール作成 / PassRole /
  ServiceLinkedRole）を付与。deploy 信頼に `refs/heads/sandbox/*` を追加。
- 運用ドキュメント: `CLAUDE.md` に「Working from issues」と sandbox ポリシー、
  `docs/infrastructure.md` に bootstrap 適用前の CI 挙動・ロール ARN 登録手順を追記。

### Changed

- **`cd-app.yml`**: デプロイを「ビルドした image で **新タスク定義リビジョンを登録** →
  そのリビジョンで migration（`uv run --no-sync alembic upgrade head`）→ サービスを新リビジョンへ
  roll」に変更（ECR は IMMUTABLE タグのため `force-new-deployment` だけでは新イメージが反映され
  なかった問題を解消）。変数 `MIGRATION_TASK_DEFINITION` → `ECS_TASK_FAMILY`。
- **api 設定**（`config.py`）: `API_DB_*` コンポーネントから `database_url` を組み立て
  （ECS の env + Secrets Manager 注入に対応）。
- Claude Code `.claude/settings.json`: **read-only な aws を allow**（`terraform apply`/`destroy`・
  `aws:*` 変更系は `ask` 維持）。
- CI/CD のワークフローを Terraform `1.13.0` に統一（`required_version >= 1.11` 要件）。

### Fixed

- **CI**: `pull_request` 起動の CI が `changes` ジョブの権限不足（`pull-requests: read` 欠如）で
  常に失敗していた問題を修正。
- **CI（infra）**: `trivy-action` の無効タグを `@v0.36.0` に、Terraform バージョン不整合を解消、
  tflint の未使用宣言（変数 / bootstrap の data source）を整理。
- **`services/api/Dockerfile` / `.dockerignore`**: `README.md` 除外解除、Alembic 設定/マイグレーション
  の同梱、`uv run --no-sync`（private subnet に egress が無くてもビルド/マイグレーションが通る）。

## [0.0.4] - 2026-06-27

### Added

- **データベース層**を追加。`api` は PostgreSQL に永続化する。
  - アプリ: SQLAlchemy 2.0 async（asyncpg）＋リポジトリパターン、Alembic マイグレーション。
    in-memory store を `ItemRepository` + `Depends(get_session)` に置換。`API_DATABASE_URL` 設定。
  - ローカル: `docker-compose.yml`（`postgres:16`）と `make db-up`/`migrate`/`makemigration`。
  - テスト: `TEST_DATABASE_URL` 未設定時は in-memory SQLite にフォールバック、CI は Postgres
    service container で `alembic upgrade head` + pytest を実行。
- **インフラ**: 最小 VPC（2 AZ・public/private subnet・IGW、app/db セキュリティグループ）と
  **RDS for PostgreSQL**（private subnet・保管時暗号化・非公開・`manage_master_user_password`
  による Secrets Manager マネージド認証・IAM 認証・Performance Insights）。
- **CD**: `cd-app.yml` に **マイグレーション専用ジョブ**を追加（`aws ecs run-task` で
  `alembic upgrade head` を VPC 内の一回限り Fargate タスクとして実行し、成功後にサービス更新）。
- ドキュメント（`CLAUDE.md` / `docs/app-development.md` / `docs/infrastructure.md`）に DB 節を追記。

## [0.0.3] - 2026-06-27

### Changed

- Terraform の state ロックを **DynamoDB から S3 ネイティブロック**（`use_lockfile = true`）へ移行。
  DynamoDB ロックテーブル・関連変数/出力/IAM 権限を削除し、`required_version` を `>= 1.11` に。
  `env/*.backend.hcl.example` を `use_lockfile = true` に更新。

### Security

- bootstrap の state バケットに、**非 HTTPS（平文 HTTP）アクセスを拒否**するバケットポリシー
  （`aws:SecureTransport=false` を Deny）を追加。

### Added

- インフラ論理構成図 `docs/images/infra-architecture.drawio.svg`（draw.io で編集可能な
  `*.drawio.svg`）を追加し、`docs/infrastructure.md` から参照。

## [0.0.2] - 2026-06-27

### Changed

- アプリ構成を刷新: バックエンドを **FastAPI**（uvicorn、`/api` 配下のルーター・
  Pydantic スキーマ・`pydantic-settings`）に、フロントエンドを **Vite + Vue 3 + TS**
  （Composition API・vue-router・Pinia・vue-tsc・Vitest・Playwright）に変更。
- API 契約を OpenAPI に一本化し、フロントの型を `make gen-types` で生成
  （`services/web/src/api/schema.ts`）。
- `infra/` を 2 層化: `infra/bootstrap/`（初回・ローカル state: state バケット /
  DynamoDB ロック / GitHub OIDC / CI IAM ロール）とアプリ層（リモート state、部分 backend）。

### Added

- GitHub Actions の CI/CD: `ci.yml`（パスフィルタ per-service）/ `cd-infra.yml`
  （PR で plan、main で apply・`production` 環境ゲート）/ `cd-app.yml`
  （ECR/ECS・S3/CloudFront）。AWS 認証は GitHub OIDC のロール引受で長期キーなし。
- `services/api/Dockerfile`（CD 用イメージ）と env 別 `tfvars` / `backend.hcl` の `*.example`。
- 開発ガイド `docs/app-development.md` と `docs/infrastructure.md`。
- Makefile に `dev` / `gen-types` / `api-dev` / `web-*` ターゲットを追加。

## [0.0.1] - 2026-06-27

### Added

- モノレポの初期構成: `infra/`(Terraform)、`services/api/`(Python・uv)、
  `services/web/`(Node/TypeScript)、`Makefile`、`pre-commit` 設定。
- Dev Container 定義（Terraform / AWS CLI / Python 3.14 / Node 24 / セキュリティツール）。
- AWS SSO セットアップスクリプト `tools/script/aws-sso-setup.sh` を追加し、
  `tools/script` を `PATH` に追加。`sso_account_id` と SSO start URL は環境固有のため
  必須オプション（既定値を埋め込まない）。
- ユーザー設定（`~/.aws` / `~/.config/gh` / `~/.claude` / `~/.history`）を名前付き
  Docker ボリュームで永続化。`init-persist.sh` で rebuild ごとに所有者を是正。
- Claude Code の設定・認証を `CLAUDE_CONFIG_DIR` で `~/.claude` に集約し永続化。
- プロジェクトメタファイル: `LICENSE`(MIT) / `CONTRIBUTING.md` /
  `CODE_OF_CONDUCT.md` / `CHANGELOG.md`。
- 開発環境ガイド `docs/development-environment.md` と `docs/README.md`。
- 公開用リポジトリ（`iwata-jawsug-jp/devcon`）への変換パブリッシュ・ワークフロー
  （Release 公開時に `devcon` → `devcon` へ変換してスナップショット公開）。
- README に Git / Claude Code / AWS SSO の初期設定手順と MIT ライセンス表示を追記。

[Unreleased]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.6.7...HEAD
[0.6.7]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.6.6...v0.6.7
[0.6.6]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.6.5...v0.6.6
[0.6.5]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.6.4...v0.6.5
[0.6.4]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.6.3...v0.6.4
[0.6.3]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.5.3...v0.6.0
[0.5.3]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.3.14...v0.4.0
[0.3.14]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.3.13...v0.3.14
[0.3.13]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.3.12...v0.3.13
[0.3.12]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.3.11...v0.3.12
[0.3.11]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.3.10...v0.3.11
[0.3.10]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.3.9...v0.3.10
[0.3.9]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.3.8...v0.3.9
[0.3.8]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.3.7...v0.3.8
[0.3.7]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.3.6...v0.3.7
[0.3.6]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.3.5...v0.3.6
[0.3.5]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.10...v0.3.0
[0.2.10]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.9...v0.2.10
[0.2.9]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.8...v0.2.9
[0.2.8]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.7...v0.2.8
[0.2.7]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.1.4...v0.2.0
[0.1.4]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.0.6...v0.1.0
[0.0.6]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/iwata-jawsug-jp/devcon/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/iwata-jawsug-jp/devcon/releases/tag/v0.0.1
