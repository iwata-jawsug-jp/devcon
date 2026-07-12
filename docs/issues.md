# Issue から実装するときのフロー

GitHub issue を実装するときの運用ルール。全体の規約は [`../CLAUDE.md`](../CLAUDE.md) を参照。

## 基本ループ

- **最新の `main` からブランチを切る。** 1 issue = 1 ブランチ。内容に応じたプレフィックスを
  使う: バグは `fix/<slug>`、機能は `feat/<slug>`、ドキュメントは `docs/<slug>`、テスト/CI
  ゲートは `test/<slug>`、インフラは `infra/<slug>`、リリース作業は `release/<slug>`。
  無関係な既存ブランチ（sandbox 等）を流用しない。
- **見つけた事象は、直す前に issue へ記録する。** デバッグは固定の 3 ステップではなくループ:
  1. **着手時** — ブランチ + 計画をコメント。
  2. **原因ごと** — 見つけた原因（特に修正の途中で CI が新たに表面化させた root cause）を、
     その修正を当てる _前_ にコメントし、続けて変更内容とコミット SHA を残す。
  3. **完了時** — 検証できた結果をコメント。
  - 事象をまとめてあとで記録しない。コメントは短く事実ベースで（diff・実行 URL）。
- **1 issue → 1 つの焦点を絞った PR。** PR 本文（とコミットメッセージ）に `Closes #N`。diff は
  その issue にスコープし、無関係な発見は新しい issue に切り出す。
- **実 AWS 環境でしか検証できない変更は、`main` へ入れる前に `sandbox/*` で検証する。**
  対象は次のいずれか（詳細な判定基準・理由は
  [development-process.md](development-process.md#いつ-sandbox-検証が必須か)）:
  - `infra/**`（Terraform リソース変更）
  - `.github/workflows/cd-*.yml`（デプロイパイプライン変更）
  - `services/**` で DB マイグレーション・認証・環境変数注入を伴う変更
    検証したら、完了時コメントまたは PR 本文に「sandbox/xxx で検証済み: `<run URL>`」の形で
    記録する（「着手時/原因ごと/完了時にコメント」の記録規律に載せる）。上記に該当しない
    通常の機能追加・バグ修正・ドキュメント変更は、`ci.yml` の green で十分（[sandbox.md](sandbox.md) 参照）。
- **CI が実際に green になるまで issue は完了ではない。** `gh pr checks <pr> --watch` で監視し、
  該当ジョブが _緑_ になるのを確認する。「トリガーされた」「走った」は成功ではない。失敗時は
  `gh run view --job <id> --log-failed` でログを読んでから「直った」と言う。`main` には
  `ci.yml` の必須チェックを強制する GitHub Ruleset（`main-ci-required`）が設定されており、
  この規律は GitHub 側でも実際に強制される（[infrastructure.md](infrastructure.md#ブランチ保護github-rulesets)）。


- **ローカル検証は CI と同じコマンドで。** ゆるいローカル変種ではなく workflow のステップを
  ミラーする。例: `make tf-lint` は CI と同じ `tflint --recursive --config`（`infra/bootstrap/`
  も走査）を回し、CI の frontend ジョブは `make ci-frontend` で一発再現できる。ゲートを変える
  ときは pre-commit / Makefile / CI の三層を揃えて更新する。
- **記録した原因が誤りと分かったら訂正する。** 調査で root cause が違うと分かったら、古い記述を
  残さず正確な原因をコメントする。
- **確認なしに `main` へマージしない。** PR は開いたまま「準備できた」と伝える。マージはユーザー
  の判断（`.claude/settings.json` に `gh pr merge` 等の allow エントリがなく、デフォルトで
  確認を挟む）。

## 関連ドキュメント

- [infrastructure.md](infrastructure.md) — CI/CD（`ci.yml` / `cd-infra.yml` / `cd-app.yml`）と
  ブートストラップ順序。CI で green を確認する際の正。
- [sandbox.md](sandbox.md) — `sandbox/*` 隔離ブランチでの実 AWS 検証（PR/マージの行き止まり）。
- [development-process.md](development-process.md) —
  開発プロセス全体・sandbox 検証要否判定表・ブランチ戦略。
- [`../CLAUDE.md`](../CLAUDE.md) — アーキテクチャと規約の正。
