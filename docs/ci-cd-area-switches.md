# CI/CD エリア別スイッチ設定手順

frontend / backend / infra の各エリアごとに、CI・CD ワークフローの実行可否を
リポジトリ変数（Repository Variables）で切り替える手順。仕組みの背景・設計判断は
[infrastructure.md](infrastructure.md) の「エリア別スイッチ」を参照。

## 仕組み（要点）

- GitHub Actions の仕様上 `on:` トリガーでは `vars` を参照できないため、
  **ジョブレベルの `if`** で変数を評価してゲートする（PR #343）。
- 判定は `vars.X != 'false'` — **未設定ならデフォルト有効**。明示的に文字列
  `false` を登録したときだけ停止する。`true` の登録は不要（削除と同義）。
- エントリジョブがスキップされると下流ジョブも `needs` 連鎖で自動スキップされる。
  スキップ時のランナー消費はゼロ（Actions タブに「skipped」の実行レコードは残る）。

## 変数一覧

| 変数               | 停止する範囲                                                            |
| ------------------ | ----------------------------------------------------------------------- |
| `BACKEND_ENABLED`  | `ci.yml` の backend / `cd-app.yml` の build → migrate → deploy-api      |
| `FRONTEND_ENABLED` | `ci.yml` の frontend / `cd-app.yml` の frontend                         |
| `INFRA_ENABLED`    | `ci.yml` の infra / `cd-infra.yml` の plan・apply（手動 dispatch 含む） |

対象外: `ci.yml` の `scripts` ジョブ（どのエリアにも属さない）、sandbox 系
ワークフロー（`ci-sandbox.yml` / `cd-app-sandbox.yml` / `cd-infra-sandbox.yml`）。

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

## 関連ドキュメント

- [infrastructure.md](infrastructure.md) — CI/CD 全体像とエリア別スイッチの設計
