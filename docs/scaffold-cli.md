# スキャフォールドCLI（copier）テンプレート化 — 作業ノート

#294（スキャフォールドCLI導入）の検討過程を記録する作業ノート。ツール選定は
[ADR-0010](adr/0010-adopt-copier-for-scaffold-cli.md)（copier 採用）、テンプレートの置き場所は
[ADR-0011](adr/0011-scaffold-template-in-place.md)（本リポジトリを in-place でテンプレート化）
で決定済み。本書はハードコード箇所の洗い出し・テンプレート変数設計・生成物検証CIの詳細を記録する。
生成手順・変数一覧の利用者向けドキュメントは [`README.md`](../README.md) を参照。

> **現状: #294 の検討項目は完了。** チェックリストは #294 本体を参照。

## ハードコード箇所の洗い出し

`copier` でテンプレート化する際に変数化・除外が必要な、プロジェクト固有の直書き箇所を種類別に
洗い出した（`grep -rl` によるリポジトリ全文検索、2026-07-14 時点）。

### A. プロジェクト名 `devcon`（想定変数: `project_name`）

| ファイル                                                                                  | 内容                                                                                                 |
| ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `infra/variables.tf:4` / `infra/bootstrap/variables.tf:4`                                 | `variable "project" { default = "devcon" }`                                                   |
| `infra/env/*.tfvars.example`（dev/prod/sandbox/golden-path-verify）                       | `project = "devcon"`                                                                          |
| `infra/env/*.backend.hcl.example`                                                         | `key = "devcon/<env>/terraform.tfstate"`（state キーの名前空間）                              |
| `.devcontainer/devcontainer.json`                                                         | コンテナ名・volume 名（`devcon-dind` 等5箇所）                                                |
| `services/frontend/vite.config.ts`                                                        | PWA manifest の `name` / `short_name` / `description`                                                |
| `services/frontend/e2e/home.spec.ts`                                                      | トップページ見出しのアサーション文字列                                                               |
| `.kiro/steering/product.md`                                                               | プロダクト説明の冒頭                                                                                 |
| `.github/scripts/tests/test_dora_metrics.py`                                              | テストフィクスチャのリポジトリ名                                                                     |
| `README.md` / `docs/README.md` / `CHANGELOG.md` / `CONTRIBUTING.md` ほか `docs/` 配下多数 | タイトル・本文中の言及（大半はテキストのみで機能に影響しないが、生成後に読者を混乱させるため要置換） |

### B. GitHub org/repo `iwata-jawsug-jp/devcon`（想定変数: `github_org` / `github_repo`）

| ファイル                                                                                                 | 内容                                                                                                                                                                                                    |
| -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `README.md`                                                                                              | CI/Release バッジの URL（`https://github.com/iwata-jawsug-jp/devcon/...`）                                                                                                                                |
| `CHANGELOG.md` / `CODE_OF_CONDUCT.md` / `docs/release.md` / `docs/sandbox.md` / `.kiro/steering/tech.md` | issue/PR 参照リンク、リポジトリ言及                                                                                                                                                                     |
| `.github/ISSUE_TEMPLATE/verification.md` / `.github/scripts/tests/test_dora_metrics.py`                  | リポジトリ名の直書き                                                                                                                                                                                    |
| `infra/bootstrap/variables.tf`                                                                           | `github_org` / `github_repo` は**既にデフォルト値なしの必須変数**で、OIDC 信頼ポリシー（`main.tf`）は `var.github_org` / `var.github_repo` から動的に組み立てられている。**対応不要**（既に一般化済み） |
| `.github/workflows/publish.yml`                                                                          | `SRC_REPO_PATH` / `DST_REPO_PATH` 等は公開ミラー配管専用。ADR-0011 で生成対象から除外する方針                                                                                                           |

### C. AWSリージョン `ap-northeast-1`（想定変数: `aws_region`）

| ファイル                                                    | 内容                                                             |
| ----------------------------------------------------------- | ---------------------------------------------------------------- |
| `infra/variables.tf:24` / `infra/bootstrap/variables.tf:10` | `variable "aws_region" { default = "ap-northeast-1" }`           |
| `infra/env/*.tfvars.example`                                | `aws_region = "ap-northeast-1"`                                  |
| `infra/env/*.backend.hcl.example`                           | `region = "ap-northeast-1"`                                      |
| `infra/CLAUDE.md`                                           | 説明文中の既定値言及（ドキュメントなので変数化ではなく文言調整） |

### D. 確認済みで対応不要な項目

調査の結果、テンプレート化にあたって追加対応が不要と分かった項目。今後同じ箇所を再調査しなくて
済むよう理由を記録する。

- **AWS アカウント ID:** リポジトリ内にハードコードはなし。`infra/bootstrap/main.tf` の OIDC
  信頼ポリシーは `local.repo`（`var.github_org`/`var.github_repo` 由来）、`infra/main.tf` の
  `local.global_name_prefix` は `data.aws_caller_identity.current.account_id` を動的参照して
  おり、既に一般化済み（#436 でグローバル一意化対応済み）。
- **カスタムドメイン:** `domain_name` 変数は `infra/env/*.tfvars.example` で既に空文字デフォルト
  （未設定ならACM/Route53を無効化）。ハードコードなし。
- **環境名（dev/prod/sandbox/golden-path-verify）:** これは golden path 自体の構造であり、
  テンプレート変数ではなくそのまま維持する規約とする。

### E. ファイルに現れない「生成後の手動設定」項目（README整備フェーズで扱う）

grep では見つからないが、`copier copy` 実行後に生成先リポジトリの Settings で人手設定が必要な
項目。#294 の完了条件「第三者が README のみで生成完了できること」に直結するため、変数設計と
合わせてここに記録しておく。

- GitHub リポジトリ変数: `AWS_DEPLOY_ROLE_ARN`、`ECR_REPOSITORY`、`INFRA_APPLY_ENABLED`、
  `LIVE_SMOKE_ENABLED` 等（`docs/ci-cd-area-switches.md` 参照）
- `infra/bootstrap` の初回 apply（OIDC プロバイダ・CI IAM ロール・state バケット作成）— ローカルで
  1度だけ実行が必要（`docs/infrastructure.md` のブートストラップ手順）
- Cognito Hosted UI・ドメイン等、AWS 側の初期セットアップ

## テンプレートリポジトリの置き場所

→ [ADR-0011](adr/0011-scaffold-template-in-place.md) で決定済み。本リポジトリ自身を copier
テンプレートのソースとする（専用リポジトリへの切り出しは行わない）。ADR-0011 に、生成対象から
除外が必要なコンテンツ（`docs/proposal/`、`docs/adr/000*`、`CHANGELOG.md`、リリース配管一式等）
の一次リストも記載している。

## テンプレート変数設計

上記 A〜C のハードコード種別を、`copier.yml`（リポジトリ直下、ドラフト）の質問項目に落とし込んだ。

| 変数名         | 型  | 既定値                   | バリデーション                                                                                                       | 対応するハードコード種別                                                      |
| -------------- | --- | ------------------------ | -------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `project_name` | str | なし（明示入力を必須化） | `^[a-z][a-z0-9-]{1,61}[a-z0-9]$`（S3バケット名・ECR・Cognitoドメイン制約に合わせた小文字英数字+ハイフン、3〜63文字） | A（プロジェクト名 `devcon`）                                           |
| `github_org`   | str | なし                     | `^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$`（GitHub org/user 名の形式）                                             | B（`itouhi`。`infra/bootstrap` の OIDC 信頼ポリシーが直接使う値と一致させる） |
| `github_repo`  | str | `{{ project_name }}`     | なし（`project_name` と別名にしたい場合のみ上書き）                                                                  | B（`devcon` のリポジトリ名部分）                                       |
| `aws_region`   | str | `ap-northeast-1`         | `^[a-z]{2}-[a-z]+-\d$`（AWS リージョン形式）                                                                         | C（`ap-northeast-1`）                                                         |

**変数化しない項目（区分Dの再掲）:** `environment`（dev/prod/sandbox）は golden path の構造その
ものであり生成時の質問にはしない。`domain_name` は元から空文字デフォルトの Terraform 変数なので
copier 側では扱わず、生成後に利用者が `env/*.tfvars` で設定する。

**テンプレート化の機構（訂正版）:** 当初 `_templates_suffix: ""` でリポジトリ全体を Jinja
レンダリング対象にし、各ファイルに `{{ project_name }}` を直書きする方針を検討したが、これは
ADR-0011 の前提（本リポジトリ自身が常に動くテンプレートであり続ける）と矛盾すると判明した。
`.devcontainer/devcontainer.json` の `"name"` に生の `{{ project_name }}` を書くと、
devcon 自身を普通に開いたときにコンテナ名がそのまま `{{ project_name }}` と表示されて
しまう（README の見出し・PWA マニフェスト名・e2e テストの期待値も同様に壊れる）。

正しい機構は、本リポジトリに既にある `tools/script/publish-to-public.sh` と同じ**コピー後の
sed 文字列置換**（copier の `_tasks` フック）。チェックイン済みファイルには一切 Jinja マーカーを
書き込まず、`copier copy` 実行後の生成先ディレクトリに対してのみ `devcon` →
`{{ project_name }}` 等の置換をかける。`_exclude` は ADR-0011 の除外リストをそのまま
`copier.yml` に落とし込んだ。

**ローカル検証済み（2026-07-14）:** `uv tool install copier` で導入し、
`copier copy --vcs-ref=HEAD --data project_name=test-project --data github_org=testorg
--data aws_region=us-east-1 ...` を実行して確認した。

- `_exclude` 対象ファイル（`docs/proposal/`、`docs/adr/0001-0011`、`CHANGELOG.md`、
  `publish.yml` 等）は生成先に含まれない
- `devcon` → `test-project`、`iwata-jawsug-jp/devcon` → `testorg/test-project`、
  `ap-northeast-1` → `us-east-1` の置換が `devcontainer.json` / `infra/variables.tf` /
  `README.md` の CI・Release バッジ URL まで正しく反映される
- 生成後のディレクトリで `devcon` / `itouhi` の残存文字列はゼロ（`.git/` を除く）
- 生成元リポジトリ（devcon 自身）のファイルは一切変更されない
- 生成先の `terraform fmt -check -recursive`（`infra/`）は green

**当初の単独 `itouhi` パターン漏れ（発見・修正済み）:** `iwata-jawsug-jp/devcon` という
org/repo パス形式の置換だけでは、`itouhi` が単独で現れる箇所（DORA 計測スクリプトの
`--owner itouhi` 例、`test_dora_metrics.py` のテストフィクスチャ）が置換されずに残った。
`itouhi` → `{{ github_org }}` の単独置換パターンを追加して解消した。

**要検討事項（解消済み、README 整備フェーズで対応）:**

- `.kiro/steering/tech.md` の `itouhi/devcon-test#20`（#438 の背景説明）への言及は、
  文字列置換すると生成先プロジェクトには存在しないリポジトリへの意味不明な参照になる問題が
  あった。devcon 自身の該当箇所を「第2消費者実証での実例」という汎用的な表現に書き換え、
  リポジトリ名への依存自体をなくして根本解決した（`_exclude` や生成後の手動修正は不要）。
- `CODE_OF_CONDUCT.md` の違反報告先が itouhi 個人の GitHub noreply メールアドレスになっており、
  単独 `itouhi` 置換をかけると実在するとは限らないメールアドレスに機械的に化けてしまう問題は、
  完全な機械的解決が難しいと判断し、README の「生成後にやること」に明記する運用で対応した
  （生成後に必ず確認・書き換えるべき項目として案内）。

**発見・修正済みの重大バグ（#515、2026-07-17）:** `_exclude` を自前定義すると copier の
標準除外（`.git`・`copier.yml`・`copier.yaml`・`~*`・`*.py[co]`・`__pycache__`・`.DS_Store`・
`.svn`）が継承されず丸ごと上書きされる（copier 9.17.0 の仕様）。これに気づかず `_exclude` を
書いていたため、実機検証では見えていなかった `devcon` 自身の全コミット履歴
（`.git/`、90MB）と `copier.yml` 自体が生成物にそのまま複製されていた（`verify-scaffold.sh` の
残存文字列チェックは `--exclude-dir=.git` で `.git` の中身を素通りしていたため検出できなかった）。
`_exclude` の先頭に copier 標準除外を明示的に足し戻し、`verify-scaffold.sh` に `.git` /
`copier.yml` / `copier.yaml` の混入を直接アサートするステップを追加して解消した。

同じ調査で `docs/adr/0001`〜`0011` の個別列挙が `0012`〜`0017`（6件）の追加に追従できておらず
生成物にそのまま出力される drift も発覚し、`docs/adr/*.md` + `!docs/adr/template.md` の
glob パターンに置き換えて解消した。あわせて `docs/org-rulesets.md`（公開ミラー用org
`iwata-jawsug-jp` 自身への適用記録）・`docs/frontend-frameworks-demo.md`（sandbox実験計画メモ）
を `_exclude` に追加した。

## 生成物の検証CI

`tools/script/verify-scaffold.sh`（`make scaffold-verify`）が `copier copy` で実際に生成し、
生成物を検証する。`ci.yml` の `scaffold` ジョブ（`copier.yml` / このスクリプト / `ci.yml` 自身の
変更で起動、エリアスイッチ対象外）から呼ばれる。

**検証範囲（スコープを意図的に絞っている）:**

- 置換漏れチェック（`devcon` / `itouhi` / `ap-northeast-1` の残存がゼロであること）
- `terraform fmt -check -recursive` / `terraform validate`（`infra/`・`infra/bootstrap/` 両層）
- backend: `uv sync` + `ruff check` + `mypy`
- frontend: `npm ci` + `eslint` + `vue-tsc --noEmit` + `vitest`（unit test）
- `devcontainer.json` / `package.json` / `tsconfig*.json` の JSON 構文チェック

**意図的に対象外にしたもの:** backend の DB 統合テスト（`pytest`、Postgres サービスコンテナが
必要）・frontend の E2E（Playwright）・infra のセキュリティスキャン（tflint/checkov/trivy）。
これらは生成物固有のリスク（文字列置換による構文破壊）を検出する目的には過剰で、既存の
backend/frontend/infra ジョブが devcon 自身に対して常時カバーしている。生成物にだけ
起こり得る問題（除外リスト・置換パターンの機能不全）に検証範囲を絞ることで、CI コスト増を
最小限にした。

**ツールバージョン:** `.devcontainer/Dockerfile` の `COPIER_VERSION`（9.17.0）を単一ソースとし、
`ci.yml` の `scaffold` ジョブも同じバージョンを pin（#109 の既存プラクティスに合わせた）。

## 今後の作業（#294 チェック項目）

- [x] ツール選定 → [ADR-0010](adr/0010-adopt-copier-for-scaffold-cli.md)
- [x] テンプレート変数設計・ハードコード箇所の洗い出し → 上記
- [x] テンプレートリポジトリの置き場所 → [ADR-0011](adr/0011-scaffold-template-in-place.md)
- [x] 生成物の検証 CI → `tools/script/verify-scaffold.sh` / `ci.yml` の `scaffold` ジョブ
- [x] 生成手順・変数一覧の README 整備 → [`README.md`](../README.md) の
      「自分の名前でプロジェクトを生成する（スキャフォールド）」節

#294 の検討項目はすべて完了。
