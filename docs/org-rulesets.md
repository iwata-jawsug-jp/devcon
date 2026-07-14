# 組織レベルの GitHub Rulesets（標準セット）

#295 の検討項目「org レベルの rulesets / branch protection の標準セット定義」に対応する設計ドキュメント。

> **現状: `iwata-jawsug-jp` org に適用済み**（2026-07-14、ruleset id `18954567`、ユーザー
> 承認のうえ Claude Code が `gh api` で作成）。適用状況は下記「適用コマンド」節の確認コマンドで
> いつでも再確認できる。

## 背景

`main-ci-required` / `sandbox-isolation`（[`docs/infrastructure.md`](infrastructure.md)・
[`docs/sandbox.md`](sandbox.md)）は devcon 1リポジトリに対する**リポジトリレベル**の
ルールセットで、`gh api repos/<org>/<repo>/rulesets` で個別に作成している。この方式は
リポジトリごとに手作業が必要で、#294 のスキャフォールドで新規プロジェクトが増えるほど
セットアップ漏れのリスクが上がる。個人アカウント（`itouhi`）には**組織レベル**の
ルールセット機能（`orgs/<org>/rulesets`、Team/Enterprise プラン以上が必要）が無いため、
これは `iwata-jawsug-jp` org（team プランで確認済み）でのみ実現できる。

## 標準セットの構成

組織レベルルールセットと、既存踏襲のリポジトリレベルルールセットを役割分担する。

### 1. 組織レベル（`iwata-jawsug-jp` の全リポジトリに一律適用）

CI ジョブ名に依存しない、リポジトリを問わず成立する基礎的な衛生ルール:

- PR を経ないマージの禁止（`pull_request` ルール）
- force-push の禁止（`non_fast_forward`）
- ブランチ削除の禁止（`deletion`）

対象は `~ALL`（org 内の全リポジトリ）または特定の命名規則
（`devcon*`、`copier` 生成物を想定）に絞る。

```bash
gh api -X POST orgs/iwata-jawsug-jp/rulesets \
  -f name='org-baseline' -f target='branch' -f enforcement='active' \
  -F 'conditions[ref_name][include][]=~DEFAULT_BRANCH' \
  -F 'conditions[repository_name][include][]=~ALL' \
  -F 'rules[][type]=pull_request' \
  -F 'rules[][type]=non_fast_forward' \
  -F 'rules[][type]=deletion'
```

### 2. リポジトリレベル（各リポジトリで個別に作成、既存パターンを踏襲）

CI ジョブ名に依存する必須ステータスチェック（`main-ci-required` 相当）は、リポジトリごとに
実際のジョブ構成が異なりうるため、引き続きリポジトリレベルのルールセットで管理する。
`docs/infrastructure.md`「ブランチ保護（GitHub Rulesets）」の手順をそのまま流用できる
（reusable workflow 化 — #295 / ADR-0012 — により、`copier` で生成したプロジェクトも
同じジョブ構成・同じ必須チェック名（`changes / check` 等）になるため、コマンドはほぼ
コピー＆ペーストで再利用できる）。

`copier copy` 生成後の「[生成後にやること](../README.md#自分の名前でプロジェクトを生成するスキャフォールド)」
に、このリポジトリレベルルールセット作成の手順を追記することが今後のタスクとして残る
（README 整備の追加分、または #298「テンプレート更新の下流追従」の一部として扱う）。

## 適用コマンド（適用済み）

上記「組織レベル」の `gh api` コマンドで作成した（`iwata-jawsug-jp` org の owner 権限、
`admin:org` スコープが必要）。適用状況の確認:

```bash
gh api orgs/iwata-jawsug-jp/rulesets --jq '.[] | {id, name, enforcement}'
```

## 再検討トリガー

- `iwata-jawsug-jp` 配下のリポジトリ数が増え、組織レベルルールセットの対象を `~ALL` から
  特定パターンへ絞り込みたくなった場合。
- 必須ステータスチェックも組織レベルで統一したくなった場合（そのためには全リポジトリの
  CI ジョブ名を揃える運用が前提になる — reusable workflow 参照が徹底されていれば現実的）。
