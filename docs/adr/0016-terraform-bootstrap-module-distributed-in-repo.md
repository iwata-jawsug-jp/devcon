# ADR-0016: Terraform bootstrap の配布は専用リポジトリを作らず devcon 自身をタグ参照で行う

- **Status:** Accepted
- **Date:** 2026-07-16
- **Deciders:** itouhi
- **Related:** #239、[Epic #300](https://github.com/iwata-jawsug-jp/devcon/issues/300)、#294、#298、#476、
  [ADR-0010](0010-adopt-copier-for-scaffold-cli.md)・[ADR-0011](0011-scaffold-template-in-place.md)・
  [ADR-0012](0012-reusable-workflow-in-repo-tag-versioned.md)（いずれも同種の「配布可能な資産を
  どこに置くか」判断の先例）

## Context

#239（2026-07-05起票）は、プラットフォームエンジニアリング評価（#153）で指摘された「golden path
としては完成度が高いが、第2の消費者が自走できる仕組み（モジュール配布）がない」という IDP 化の
ギャップを埋めるため、`infra/bootstrap/`（OIDC プロバイダ・CI IAM ロール・state バケット、ほぼ汎用）
をバージョンタグ付き Terraform モジュールとして**専用リポジトリ**（例: `terraform-modules`）へ
切り出す案を提案していた。

その後、#239 起票時には無かった2つの決定が積み重なっている。

1. **#294（スキャフォールドCLI、ADR-0010/0011）が実装済み**: `copier copy gh:iwata-jawsug-jp/devcon
<生成先>` で `infra/bootstrap/` を含むリポジトリ全体を、プレースホルダ置換済みの状態で第三者が
   取得できる。「第2の消費者が自走できる」という #239 の目的の大部分は、既にこの経路で実現している。
2. **ADR-0011（スキャフォールドテンプレートは同一リポジトリ内に配置）・ADR-0012（reusable workflow
   も専用リポジトリを作らず本リポジトリ内でタグ参照）が、同種の論点で「専用リポジトリを作らない」
   という判断を下している。** 理由はどちらも共通で、devcon 自身がその配布物の最初の消費者
   であり続けること（ドッグフーディング）によって劣化・drift に自分自身が気づける、という点。

#239 が提案する「専用リポジトリ」は、この確立済みの方針と矛盾する。技術的にも、Terraform の
module `source` 引数（および `terraform init -from-module=`）は任意の Git リポジトリの
サブディレクトリを直接参照できる
（`source = "git::https://github.com/iwata-jawsug-jp/devcon.git//infra/bootstrap?ref=vX.Y.Z"`）ため、
専用リポジトリを作らなくても「タグ付きバージョン参照」という #239 が欲しかった性質は満たせる。
`infra/bootstrap/` は既に `providers.tf`/`versions.tf` を持つ自己完結した構成で、`backend` ブロックを
持たない（bootstrap 自身がローカル state で適用される層のため、`infra/CLAUDE.md` 参照）ため、
モジュールとして参照される際にも構造上の障害はない。

## Decision

1. **Terraform モジュール専用の別リポジトリは作らない。** `infra/bootstrap/`（および将来切り出す
   価値のある他の infra 部品）は devcon 自身に残し、Git source + タグ参照で配布する。
2. **バージョン参照は既存の `v*` リリースタグを使う**（ADR-0012 と同じ判断）。bootstrap 専用の
   別バージョン体系は新設しない。
3. **2つの消費経路を並立させる**（いずれも今回のコード変更なしで既に機能する）:
   - **新規プロジェクト一式が欲しい場合**: `copier copy gh:iwata-jawsug-jp/devcon <生成先>`（#294）。
     frontend/backend/infra/CI 一式がプレースホルダ置換済みで手に入る、推奨経路。
   - **bootstrap 部分だけを既存/別プロジェクトへ軽量に取り込みたい場合**:
     `terraform init -from-module="git::https://github.com/iwata-jawsug-jp/devcon.git//infra/bootstrap?ref=vX.Y.Z"`。
     コピー一式は不要で、OIDC/state バケット/CI ロールの構成だけを取り込める。
4. **devcon は非公開リポジトリのため、この Git source 参照は認証情報を持つ消費者（itouhi
   自身の他リポジトリ等）に限られる。** ADR-0012 が reusable workflow の参照先を公開ミラー
   （`iwata-jawsug-jp/devcon`）にしたのと同じ理由で、真の第三者（fork 元アカウント外）は公開ミラー
   側のタグを参照する必要がある。
5. **実証**: 隔離した検証用ディレクトリから `terraform init
-from-module="git::https://github.com/iwata-jawsug-jp/devcon.git//infra/bootstrap?ref=v0.3.12"`
   を実行し、（devcon-test と同じ itouhi アカウントの認証情報で）ダウンロード・provider
   初期化・`terraform validate` が成功することを確認した。AWS には一切触れていない（state/認証
   情報を伴う実 apply の検証は、実際に devcon-test 側でこの経路を使う際に行う）。
6. #239 が提案していた「モジュール専用リポジトリ + 独立した CI + 独立したバージョン体系」は、
   本 ADR の決定に置き換える（superseded）。#239 の根本目的（IDP ギャップ: 第2消費者の自走）は
   #294（コピー一式取得）と本 ADR（軽量タグ参照取り込み）の組み合わせで満たされたと判断し、
   #239 はこの ADR を根拠にクローズする。

## Consequences

- **良い面:**
  - 新規リポジトリを持たないため、保守対象が増えない・2つの「真実の情報源」間の drift リスクが
    構造的に発生しない（ADR-0011/0012 と同じ利益）。
  - devcon 自身が `infra/bootstrap/` の唯一の実消費者であり続けるため、劣化に自分自身の
    運用で気づける。
  - 既存のリリースタグ運用（`docs/release.md`）にそのまま乗るため、新しい配布・バージョン管理の
    仕組みを増やさない。
- **トレードオフ・新たに生じる負担:**
  - Git source 参照は Terraform Registry のようなバージョン範囲解決（`~> 1.0` 等）ができず、
    消費側は常に**具体的なタグを1つ指定**する必要がある。バージョンの更新追従は消費側の作業
    （#298「テンプレート更新の下流追従」の対象）として残る。
  - 非公開リポジトリのため、真の第三者（itouhi 自身の管理下にないアカウント）は公開ミラー側の
    タグしか参照できない。開発用/公開用のどちらを参照すべきかを README で明示する必要がある
    （reusable workflow と同じ運用上の注意点）。
  - `infra/bootstrap/` が「他プロジェクトから参照されるモジュールでもある」という性質を持つため、
    今後の変更（IAM ポリシーの追加等）はこの消費経路への影響も意識する必要がある（ただし現状の
    唯一の実消費者は devcon 自身であり、破壊的変更をした場合は自分自身の bootstrap 運用が
    真っ先に検知する）。
- **再検討トリガー:** 将来、genuinely 独立したリリースサイクル・バージョニング要件を持つ複数の
  infra モジュール（例: web ホスティング用モジュールが bootstrap よりはるかに高頻度でリリースされる
  等）を抱えるようになった場合、専用リポジトリ・Terraform Registry 相当の配布の再検討トリガーとする。
