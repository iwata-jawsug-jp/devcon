# ADR-0015: live-smoke ゲートを reusable workflow に切り出す

- **Status:** Accepted
- **Date:** 2026-07-15
- **Deciders:** itouhi
- **Related:** [#376](https://github.com/iwata-jawsug-jp/devcon/issues/376)（残タスク「reusable
  workflow化」）、[ADR-0008](0008-live-smoke-playwright-project-with-disposable-cognito-user.md)
  （live-smoke 自体の設計）、[ADR-0012](0012-reusable-workflow-in-repo-tag-versioned.md)（CI 側の
  reusable workflow 化。本 ADR はその CD 版）

## Context

`cd-app-sandbox.yml`（sandbox post-deploy）・`cd-app.yml`（main post-deploy）・
`cd-sandbox-cycle.yml`（週次エフェメラルサイクル、#376 PR④）の3ワークフローが、それぞれ独立に
「disposable Cognito ユーザーの作成 → live-smoke 実行 → artifact アップロード → ユーザー削除」
という同じ約90行のジョブを持っていた（`cd-sandbox-cycle.yml` 実装時のコメントに「reusable
workflow化はせず、#295で解消する想定のdriftを意図的に許容する」と明記されており、この負債は
発生時点で認識済みだった）。ADR-0012 が CI 側（`ci.yml`/`ci-sandbox.yml`）で解消した drift と
同種の問題が CD 側で発生していたため、同じ手法（本リポジトリ内 `.github/workflows/reusable-*.yml`、
`workflow_call`）を適用する。

3ワークフロー間には無視できない差異があった:

- var 名の prefix（`SANDBOX_CLOUDFRONT_DOMAIN_NAME` vs `CLOUDFRONT_DOMAIN_NAME` 等）
- 失敗時の扱い: `cd-app-sandbox.yml` は単純 blocking（issue 起票なし）、`cd-app.yml` は
  blocking + issue 自動起票、`cd-sandbox-cycle.yml` は alerting（issue 起票のみ、teardown を
  止めない）
- `cd-app.yml` のみ `environment: production` と `LIVE_SMOKE_ENABLED` opt-in ゲートを持つ
- artifact 名の prefix

## Decision

**`reusable-live-smoke.yml` を「実行するだけ」の機構として切り出し、失敗時の扱い（blocking か
alerting か・issue を起票するか・opt-in ゲート）はすべて呼び出し側に残す。**

1. **outputs 経由でポリシーを呼び出し側に渡す。** reusable workflow は `outcome` /
   `failed_step` / `artifact_name` を job output として返すだけで、issue 起票はしない。
   `cd-app.yml` は `smoke-test-gate` という後続ジョブを新設し、`outcome == 'failure'` の場合に
   issue を起票してから明示的に `exit 1` する（reusable workflow 内部の smoke ステップは
   `continue-on-error: true` で握りつぶされているため、素通しでは呼び出しジョブ自体は
   success 扱いになってしまう）。`cd-sandbox-cycle.yml` も同様の後続ジョブを持つが `exit 1`
   はしない（alerting のみ、teardown を止めない）。`cd-app-sandbox.yml` は
   `continue_on_error` を渡さない（デフォルト `false`）ため、失敗がそのままジョブ失敗になる
   単純な blocking のまま。
2. **`environment` を呼び出し側から渡す input にする（reusable workflow 内のジョブに直接
   `environment: production` を書かない）。** OIDC の `role-to-assume` を実行するのは
   reusable workflow の内部ジョブであり、`infra/bootstrap/main.tf` の `deploy_subjects` は
   `ref:refs/heads/main` **または** `environment:production` の `sub` claim を要求する
   （[docs/infrastructure.md](../infrastructure.md)）。`environment` 保護はこの OIDC trust
   policy の一部であって装飾ではないため、実際に `configure-aws-credentials` を呼ぶジョブに
   付いていなければ `cd-app.yml` の smoke-test で AssumeRoleWithWebIdentity が失敗する。
   `cd-app-sandbox.yml`/`cd-sandbox-cycle.yml` は元々 GitHub Environments を使わない設計
   （`cd-app-sandbox.yml` の既存コメント: Environments を使うと OIDC トークンの `sub` claim が
   `environment:sandbox` に変わり、trust policy が許可していないため壊れる）なので、
   `environment` input を渡さず空文字のままにする。
3. **`should_run` input で opt-in ゲートを表現する（呼び出しジョブに `if:` を付けない）。**
   ADR-0012 の教訓（呼び出しジョブへの `if:` は check 名を `<job> / check` から素の `<job>` に
   変えてしまう）をそのまま踏襲。`cd-app.yml` は `should_run: ${{ vars.LIVE_SMOKE_ENABLED ==
'true' }}` を渡す。もっとも、post-deploy ジョブは `main-ci-required` の対象ではないため
   ADR-0012 ほど致命的ではないが、一貫性のため同じ形にする。
4. **`base_url` は呼び出し側で `https://` を結合してから渡す。** reusable workflow 側は
   「3入力（`base_url`/`user_pool_id`/`role_arn`）がすべて空でなければ configured」という
   単純な判定しかしない。呼び出し側で `vars.X != '' && format('https://{0}', vars.X) || ''`
   のように条件付き結合しないと、var 未設定時に `https://`（空でない文字列）になり
   「未設定」判定が機能しなくなる。

## Consequences

- **良い面:** 3ワークフロー合計で270行程度の重複を1ファイルに統合。今後 live-smoke の実行手順
  （S1〜S3・disposable user 戦略等）を変える際は1箇所の変更で3ワークフローに反映される。
  ADR-0012 と同じ「mechanism は共有・policy は呼び出し側」という設計原則を CD 側にも展開できた。
- **コスト:** ジョブが1段階深くなり（`smoke-test / check`）、`cd-app.yml`/`cd-sandbox-cycle.yml`
  は issue 起票が別ジョブ（`smoke-test-gate`/`file-issue-on-smoke-failure`）に分かれたぶん
  ワークフローの見通しがやや複雑になった。
- **未検証:** 本 ADR 作成時点で `LIVE_SMOKE_ENABLED` は無効のままのため、`cd-app.yml` 側の
  `environment: production` 経由の OIDC 導線は実機で再検証されていない。有効化する際は
  #376 の完了条件（意図的な構成破壊での fail 検出）と同様の実機確認を行うこと。
- **再検討トリガー:** 下流リポジトリ（#295 の公開ミラー配布と同じ形）がこの
  `reusable-live-smoke.yml` を参照したいというニーズが出た場合、ADR-0012 と同じタグ参照方式
  （公開ミラー `iwata-jawsug-jp/devcon` 経由）を適用する。
