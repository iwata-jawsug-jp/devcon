# ADR-0022: GH_CHECK_SETUP_TOKEN のスコープを Read/Write に拡張し bootstrap.sh write でも使う

- **Status:** Accepted
- **Date:** 2026-07-21
- **Deciders:** itouhi
- **Related:** [ADR-0021](0021-codespaces-user-secrets-for-check-setup-token.md)（本ADRが
  Superseded とする前提の元ADR）, `tools/script/bootstrap.sh`,
  `.env.check-setup.example`, [development-environment.md](../development-environment.md)
  「GitHub Codespaces では」節

## Context

ADR-0021 は `GH_CHECK_SETUP_TOKEN` を「確認専用」の最小権限 PAT（`Administration:
Read-only` + `Variables: Read-only`）として設計し、`check-devenv-setup.sh` /
`check-repo-vars.sh` の読み取り専用チェックにのみ使う前提だった。

一方 `tools/script/bootstrap.sh write`（`cmd_write`）は、`state_bucket_name` /
`ci_plan_role_arn` / `ci_deploy_role_arn` / project 名の4つをリポジトリ変数として
`gh variable set` で書き込む必要がある。GitHub Codespaces の既定認証（Codespaces注入の
`GITHUB_TOKEN`）はこの書き込み権限を持たないことがあり（#516/#520 と同種）、これまでは
権限不足時に `GH_TOKEN=<token> ./tools/script/bootstrap.sh write` のように書き込み権限を
持つ別トークンをそのつど明示指定する運用だった。この運用は `GH_CHECK_SETUP_TOKEN` が
Codespacesユーザーシークレット経由で自動注入される仕組み（ADR-0021）の恩恵を受けられず、
書き込みのたびに手動でトークンを用意し直す必要がある。

## Decision

**`GH_CHECK_SETUP_TOKEN` の PAT スコープを `Variables: Read-only` から `Variables: Read
and write` に拡張し（`Administration: Read-only` は変更しない）、`bootstrap.sh write` の
`gh variable set` にも `resolve_published_values`（recover/adopt）と同じトークン発見
ロジック（1. 環境変数が既にセット済みならそれを使う、2. 無ければ `.env.check-setup` を
読む）を適用する。**

- トークン名・発見ロジック・優先順位（環境変数 > `.env.check-setup`）は変更しない。
  Codespacesユーザーシークレットからの自動注入という運用も ADR-0021 のまま引き継ぐ。
- 用途が「確認専用（読み取りのみ）」から「確認 + bootstrap の書き込み配線用」に変わるため、
  `.env.check-setup.example` のPAT発行手順・`development-environment.md`「GitHub
  Codespaces では」節・`bootstrap.sh` 内のコメントを、スコープが読み取り+書き込みである
  旨に更新する。変数名 `GH_CHECK_SETUP_TOKEN` 自体は据え置く（別名の書き込み専用トークンを
  新設しない）。

### 見送った代替案

- **別名の書き込み専用トークンを新設する**（例: `GH_BOOTSTRAP_WRITE_TOKEN`）: 却下。
  Codespacesユーザーシークレット/`.env.check-setup` という同じ発見ロジックをトークン2本分
  重複させることになり、PATを2本発行・管理する運用負担が増えるだけでメリットが薄い。
- **現状維持（`write` は `GH_TOKEN=<token>` の都度明示指定のまま）**: 却下。
  `GH_CHECK_SETUP_TOKEN` の発見ロジック（Codespacesユーザーシークレットでの自動注入）を
  書き込みにも使いたいという明示的な要望があった。

## Consequences

- **良い面:**
  - Codespacesユーザーシークレットを一度設定すれば、`check-setup`/`check-repo-vars` の
    確認だけでなく `bootstrap.sh write` の書き込みも自動化され、書き込みのたびに
    `GH_TOKEN=<token>` を明示指定する必要がなくなる。
  - トークンの発見ロジック・優先順位は変更しないため、`check-devenv-setup.sh` /
    `check-repo-vars.sh` 側の実装・ドキュメントは変更不要。
- **トレードオフ:**
  - `GH_CHECK_SETUP_TOKEN` という名前と実際のスコープ（読み取り+書き込み）が乖離する。
    「確認専用」という ADR-0021 時点の説明を、書き込みも含む説明に各所（
    `.env.check-setup.example`・`development-environment.md`・スクリプト内コメント）で
    更新する必要がある。
  - 既に `Variables: Read-only` スコープで PAT を発行済みの開発者が `bootstrap.sh write`
    を使うには、PAT を再発行（スコープに `Variables: Write` を追加）する必要がある。
    読み取り専用チェック（`check-devenv-setup.sh`/`check-repo-vars.sh`）は既存の
    Read-only PAT のままでも引き続き動作する（書き込み権限は `cmd_write` の
    `gh variable set` でのみ使われる）。
- **再検討トリガー:** 書き込み系の用途がさらに増え、「確認専用」という当初の意味合いを
  改めて分離したくなったら、見送った別名の書き込み専用トークン案を再検討する。
