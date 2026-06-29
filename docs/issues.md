# Issue から実装するときのフロー

GitHub issue を実装するときの運用ルール。全体の規約は [`../CLAUDE.md`](../CLAUDE.md) を参照。

## 基本ループ

- **最新の `main` からブランチを切る。** 1 issue = 1 ブランチ。バグは `fix/<slug>`、機能は
  `feat/<slug>`。無関係な既存ブランチ（sandbox 等）を流用しない。
- **見つけた事象は、直す前に issue へ記録する。** デバッグは固定の 3 ステップではなくループ:
  1. **着手時** — ブランチ + 計画をコメント。
  2. **原因ごと** — 見つけた原因（特に修正の途中で CI が新たに表面化させた root cause）を、
     その修正を当てる _前_ にコメントし、続けて変更内容とコミット SHA を残す。
  3. **完了時** — 検証できた結果をコメント。
  - 事象をまとめてあとで記録しない。コメントは短く事実ベースで（diff・実行 URL）。
- **1 issue → 1 つの焦点を絞った PR。** PR 本文（とコミットメッセージ）に `Closes #N`。diff は
  その issue にスコープし、無関係な発見は新しい issue に切り出す。
- **CI が実際に green になるまで issue は完了ではない。** `gh pr checks <pr> --watch` で監視し、
  該当ジョブが _緑_ になるのを確認する。「トリガーされた」「走った」は成功ではない。失敗時は
  `gh run view --job <id> --log-failed` でログを読んでから「直った」と言う。
- **ローカル検証は CI と同じコマンドで。** ゆるいローカル変種ではなく workflow のステップを
  ミラーする。例: CI は `tflint --recursive`（`infra/bootstrap/` も走査）を回すが `make tf-lint`
  は回さない。green な Makefile ターゲットは CI が green である証明にはならない。
- **記録した原因が誤りと分かったら訂正する。** 調査で root cause が違うと分かったら、古い記述を
  残さず正確な原因をコメントする。
- **確認なしに `main` へマージしない。** PR は開いたまま「準備できた」と伝える。マージはユーザー
  の判断（`.claude/settings.json` のゲートも参照）。

## 関連ドキュメント

- [infrastructure.md](infrastructure.md) — CI/CD（`ci.yml` / `cd-infra.yml` / `cd-app.yml`）と
  ブートストラップ順序。CI で green を確認する際の正。
- [`../CLAUDE.md`](../CLAUDE.md) — アーキテクチャと規約の正。
