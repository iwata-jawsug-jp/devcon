# CI/CD エリア別スイッチ設定手順

frontend / backend / infra の各エリアごとに、CI・CD ワークフローの実行可否を
リポジトリ変数（Repository Variables）で切り替える手順。仕組みの背景・設計判断は
[infrastructure.md](infrastructure.md) の「エリア別スイッチ」を参照。

> このリポジトリが使う全リポジトリ変数（bootstrap 配線・本番/sandbox アプリ用も含む）の
> 一覧は [repository-variables.md](repository-variables.md) を参照。本書はスイッチ系8個の
> 詳しい設定手順に特化している。

## 仕組み（要点）

- GitHub Actions の仕様上 `on:` トリガーでは `vars` を参照できないため、
  **ジョブレベルの `if`** で変数を評価してゲートする（PR #343）。
- 判定は `vars.X != 'false'` — **未設定ならデフォルト有効**。明示的に文字列
  `false` を登録したときだけ停止する。`true` の登録は不要（削除と同義）。
- エントリジョブがスキップされると下流ジョブも `needs` 連鎖で自動スキップされる。
  スキップ時のランナー消費はゼロ（Actions タブに「skipped」の実行レコードは残る）。

## 変数一覧

| 変数                  | 停止する範囲                                                            |
| --------------------- | ----------------------------------------------------------------------- |
| `BACKEND_ENABLED`     | `ci.yml` の backend / `cd-app.yml` の build → migrate → deploy-api      |
| `FRONTEND_ENABLED`    | `ci.yml` の frontend / `cd-app.yml` の frontend                         |
| `INFRA_ENABLED`       | `ci.yml` の infra / `cd-infra.yml` の plan・apply（手動 dispatch 含む） |
| `SCAFFOLD_ENABLED`    | `ci.yml` / `ci-sandbox.yml` の `scaffold` ジョブ（#294）                |
| `TREE_HEALTH_ENABLED` | `ci.yml` / `ci-sandbox.yml` の `tree-health` ジョブ（#699）             |

<!-- audience:no-generate -->

`SCAFFOLD_ENABLED` は他の3つと違い `scaffold` ジョブは特定のエリアに属さない横断ジョブ
（`scripts`/`gen-types` と同じ）だが、判定の極性・既定値は上記3つと同じオプトアウト
（`!= 'false'`、未設定なら有効）。`backend-go` の `BACKEND_GO_ENABLED` と同様に
`ci-sandbox.yml` の `scaffold` でも同じ変数を尊重する（他のエリア別スイッチが
`ci-sandbox.yml` では効かないのと対照的 — sandbox 側は「変更検知に基づくスキップ」ではなく
「このジョブ自体を止める/止めない」という単純な on/off なので、ci.yml と同じ扱いで揃える）。

<!-- /audience:no-generate -->

`TREE_HEALTH_ENABLED` も判定の極性・既定値は上記と同じオプトアウト（`!= 'false'`、未設定なら
有効）で、`ci-sandbox.yml` でも同じ変数を尊重する点は `SCAFFOLD_ENABLED` と同じだが、
**変更検知（`needs.changes.outputs.*`）ではゲートしない**点が他のスイッチと異なる。
リンク切れは「変更されたファイル」ではなく「削除・リネームされた参照先ファイル」によっても
起きるため、path-filter方式では見逃しが生じる（索引ファイル自体が変更されなくても、参照先が
消えればリンク切れになる）。そのためこのジョブは `should_run` の判定にファイル変更検知を
一切使わず、変数のON/OFFだけで毎回4本のツリー全体を検査する。

対象外: `ci.yml` の `scripts` ジョブ（専用スイッチなし）・`gen-types` ジョブ（#638。
backend/backend-go/frontend 横断のため、いずれかが変更されたときに実行——専用スイッチ
ではなく3エリアの変更検知の OR で `should_run` を決めている）、sandbox 系ワークフロー
（`cd-app-sandbox.yml` / `cd-infra-sandbox.yml`。`ci-sandbox.yml` は上記の通り一部例外）。
`ci.yml` の backend-go は `BACKEND_GO_ENABLED` で止めるが、これは極性が逆（オプトイン）
——下記「オプトイン方式のスイッチ」を参照。`ci-sandbox.yml` の backend-go だけは例外で、
このオプトインスイッチの対象**内**（他エリアと違い「変更検知でスキップ」ではなく
「未リリース機能をそもそも走らせない」ためのスイッチなので、sandbox でも同じ扱い）。

## 前提

- リポジトリの **Variables を編集できる権限**（admin または
  `Manage repository variables` を含むロール）。
- CLI で操作する場合は `gh auth status` が通ること（Dev Container には `gh` 導入済み）。

## 設定手順（gh CLI）

```bash
# 停止（値は文字列 "false" — これ以外の値はすべて「有効」扱い）
gh variable set BACKEND_ENABLED --body "false"
gh variable set FRONTEND_ENABLED --body "false"
gh variable set INFRA_ENABLED --body "false"
gh variable set SCAFFOLD_ENABLED --body "false"
gh variable set TREE_HEALTH_ENABLED --body "false"

# 現状確認
gh variable list

# 復帰（削除 = 未設定 = 有効。--body "true" でも同じ）
gh variable delete BACKEND_ENABLED
```

## 設定手順（Web UI）

1. リポジトリの **Settings → Secrets and variables → Actions** を開く。
2. **Variables** タブ →「**New repository variable**」。
3. Name に変数名（例: `BACKEND_ENABLED`）、Value に `false` を入力して保存。
4. 復帰するときは該当変数を削除するか、Value を `true` に更新する。

## 動作確認

1. スイッチを `false` にした状態で、対象エリアのパスに変更を含む PR を作成
   （または push）する。
2. Actions タブ（`gh pr checks <PR番号>` / `gh run list` でも可）で、対象ジョブが
   **skipped** になっていることを確認する。他エリアのジョブは通常どおり走る。
3. 変数を削除（または `true` に更新）して再 push し、ジョブが実行に戻ることを
   確認する。`if` は実行開始時に評価されるため、**変数変更後に新しくトリガー
   された実行から**反映される（実行中のランには影響しない）。

## 注意事項

- **skipped は required status check として合格扱い**。スイッチ OFF の間は
  そのエリアの検証なしで PR がマージ可能になる。長期間の OFF 運用は避け、
  用が済んだら速やかに復帰させること。
- 変数の値は**文字列**。`false` 以外（`0`、`no`、空文字列など）はすべて
  「有効」と判定される。
- 公開ミラー・fork では変数が未設定のため、常にデフォルト（有効）で動く。
- ワークフロー自体を完全に止めたい（実行レコードも残したくない・
  `workflow_dispatch` も含めて封じたい）場合は、GitHub 標準の
  `gh workflow disable <workflow>` / `gh workflow enable <workflow>` を使う。
  ただし状態がコード・設定として見えなくなる点に注意。

## オプトイン方式のスイッチ（別方式・デフォルト無効）

以下の3つは、上記のエリア別スイッチとは**極性が逆**の専用スイッチ。混同しないよう
区別して扱うこと。

| 項目           | エリア別スイッチ（本書冒頭）                              | オプトイン方式                                                   |
| -------------- | --------------------------------------------------------- | ---------------------------------------------------------------- |
| 判定           | `vars.X != 'false'`                                       | `vars.X == 'true'`                                               |
| 未設定時の既定 | **有効**（オプトアウト）                                  | **無効**（オプトイン）                                           |
| 有効化する値   | （何もしない＝既定で有効）                                | 文字列 `true` を明示的に設定                                     |
| 対象           | `ci.yml` / `cd-app.yml` / `cd-infra.yml` のエリア別ジョブ | 下記の個別ジョブのみ（同ワークフローの他ジョブは通常どおり動く） |

### `LIVE_SMOKE_ENABLED`（`cd-app.yml` の `smoke-test`）

`smoke-test`（第4のゲート、#373/#376、ADR-0008）は本番デプロイをブロックする新しい
ゲートで、`infra/bootstrap/` の `ci_deploy_auth` に追加した Cognito 管理権限
（人力適用・#376）が反映されていないと実行するたびに失敗する。デフォルト有効にすると、
この前提が整う前の `main` デプロイを無条件でブロックしてしまうため、デフォルト無効の
オプトインにしている。

```bash
# 有効化（infra/bootstrap 適用・sandbox での動作確認後）
gh variable set LIVE_SMOKE_ENABLED --body "true"

# 無効化に戻す（変数を削除するだけでもよい — 未設定は無効）
gh variable delete LIVE_SMOKE_ENABLED
```

### `INFRA_APPLY_ENABLED`（`cd-infra.yml` の `apply-dev`/`apply-prod`）

`apply-dev`/`apply-prod` は既に `workflow_dispatch` 限定（`main` 以外からは実行不可、#301）
だが、これに加えて `INFRA_APPLY_ENABLED` を `true` にしない限り実行されない**二重の鍵**に
している。`apply-dev`/`apply-prod`（実行対象は `workflow_dispatch` の `environment` 入力
`dev`/`prod` で選択、デフォルト `dev`）は実際に AWS インフラを変更する唯一のジョブで、
`apply-prod` では `LIVE_SMOKE_ENABLED` の前提となる Cognito 管理権限もここで反映される。
`INFRA_ENABLED`（上記のエリア別スイッチ）は `ci.yml` の infra 静的チェックと
`cd-infra.yml` の `plan` も含めて止めてしまうため、`apply-dev`/`apply-prod` だけを対象に
した別変数にしている（静的チェック・`plan` は AWS へ変更を加えないため、既定どおり常時
有効のままにする）。

```bash
# 有効化（apply を実行する回だけ、実行前に設定）
gh variable set INFRA_APPLY_ENABLED --body "true"

# 無効化に戻す（apply 後は速やかに戻すことを推奨）
gh variable delete INFRA_APPLY_ENABLED
```

### `BACKEND_GO_ENABLED`（`ci.yml` / `ci-sandbox.yml` の `backend-go`）

services/backend/go（Lambda-only、ADR-0024）はまだ Phase 3（#640）で CD 未実装の実験的
エリアなので、他のエリア別スイッチ（デフォルト有効）とは逆に、使う作業ブランチ／PR で
明示的に `true` を設定したときだけ CI が走るオプトインにしている。未設定・削除時は
無効（skip）。`ci-sandbox.yml` の `backend-go` も同じスイッチで止まる（同ファイルの他
ジョブは #153 finding 7 の設計どおり全エリア無条件実行だが、backend-go だけは正式リリース
前の機能を sandbox でも無条件で走らせないための例外）。backend-go を sandbox ブランチで
検証したい場合は、対象ブランチ／PR に対して明示的に `true` を設定すること。

**ローカル PC の `make setup`/`lint`/`test`/`security`・pre-commit フックはこのスイッチの
対象外**（意図的）。これらは backend-go を実装・検証するための開発ツールチェーンそのもの
であり、Epic #636 の実装作業（Phase 2/3）は現在進行中のため、ここを止めると実装作業自体が
ブロックされてしまう。このスイッチが止めているのは「CI/CD 上で正式機能として検証・合格
扱いにすること」であって、ローカルでの開発行為ではない。`make dev` はそもそも Go backend
を起動しない（Lambda 専用設計のため常駐サーバーとして混入する経路が無い）ので対策不要。

```bash
# 有効化（backend-go に変更を入れて検証したい間だけ）
gh variable set BACKEND_GO_ENABLED --body "true"

# 無効化に戻す（既定に戻すだけなら削除でよい）
gh variable delete BACKEND_GO_ENABLED
```

## 関連ドキュメント

- [infrastructure.md](infrastructure.md) — CI/CD 全体像とエリア別スイッチの設計
