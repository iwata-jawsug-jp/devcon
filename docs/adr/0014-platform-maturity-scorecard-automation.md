# ADR-0014: プラットフォーム成熟度スコアカードの自動化方式

- **Status:** Accepted
- **Date:** 2026-07-15
- **Deciders:** itouhi
- **Related:** [#297](https://github.com/iwata-jawsug-jp/devcon/issues/297),
  [ADR-0006](0006-dora-deployment-frequency-and-lead-time-definitions.md)（同型の週次集計基盤）,
  [`docs/metrics/scorecard-criteria.md`](../metrics/scorecard-criteria.md)（採点基準そのものの定義）

## Context

`docs/metrics/scorecard-criteria.md` で 10 軸の採点基準（1〜5 点レベル定義）と
Golden Path/IDP 2 総合点への集約方法は定義済み（#297 項目 5、完了）。残る項目 1〜4
（メタデータ定義・自動化・scheduled workflow・可視化）をどう実装するかを決める。

検討の起点は #237（DORA 計測）の実績: ADR-0006 で計測定義を決め、`dora_metrics.py`
（stdlib のみ・GitHub API を叩いて集計）と `metrics-dora.yml`（`workflow_dispatch` のみ・
`docs/metrics/` に月次スナップショットを追記・`chore/*` ブランチへ push してリンク提示）という
組み合わせで実装されている。この構成をそのまま流用するのが最も低コスト。

10 軸のうち、機械的に検証できるのは一部の項目（issue #297 本文が例示: カバレッジ閾値の有無・
必須ワークフローの存在・tflint/checkov の有効化・DORA データの存在）に限られ、残りは定性的な
判断が必要（例: 「ドキュメントが実装と一致しているか」）。全軸を自動採点する設計は無理があり、
過剰実装になる。

## Decision

### 1. メタデータは `docs/metrics/scorecard/catalog.json`（YAML ではなく JSON）

catalog-info 相当のメタデータ（owner・golden path バージョン・軸ごとのスコアと根拠）を
`docs/metrics/scorecard/catalog.json` に置く。人がレビューして更新する「宣言スコア」を持つ
（軸の性質上、多くのレベルは定性判断を含むため、全自動採点はしない）。

**YAML ではなく JSON にした理由**: `.github/scripts/` は `dora_metrics.py` 以来
「stdlib のみ・サードパーティ依存なし」を明文的な方針にしている（Makefile
`## ---- Metrics (.github/scripts, stdlib-only) ----` コメント参照）。YAML パースには
PyYAML が要るため、CI に `pip install` ステップを増やしてこの方針を崩すよりも、標準ライブラリの
`json` で読める JSON を採用する。issue #297 の「catalog.yaml 等」という表現はフォーマットを
限定していないため、この選択はスコープ内。

### 2. 自動化は「宣言スコアと機械信号のクロスチェック」方式（全軸自動採点はしない）

`.github/scripts/scorecard_metrics.py` が catalog.json の宣言スコアを読み、10 軸それぞれについて
機械的に検出できる signal（ファイル存在・grep によるパターン検出）を実行し、
**「宣言スコアがレベル4以上なのに、レベル4の機械信号が揃っていない」場合にのみ警告を出す**
（`⚠️ 要確認`）。スコアそのものを機械的に確定させるのではなく、**ドリフト検知**に絞る。

実装時に、この仕組み自体が実際に効果を発揮する例が見つかった: 当初 API 契約管理を 4 点と
見積もっていたが、`make gen-types` はあっても CI 側に生成物と実装の一致を検証するステップが
存在しないことが機械チェックで判明し、3 点に修正した（`docs/metrics/scorecard-criteria.md`
の初期ベースラインも合わせて修正）。

`--strict` フラグを付けると不整合が1件でもあれば非ゼロ終了する（将来 CI の PR ゲートに
組み込みたくなった場合のためのフックとして用意。現時点では scheduled workflow からは
非 strict で呼び、警告はレポートに出すだけで blocking にはしない）。

### 3. workflow は `metrics-dora.yml` と同じ構成（`workflow_dispatch` のみ・ブランチ push）

`.github/workflows/metrics-scorecard.yml` を新設し、`metrics-dora.yml` と同じ構成にする:

- **`workflow_dispatch` のみ**（`schedule` は使わない）。理由は ADR-0006/metrics-dora.yml と同じ:
  この monorepo は学習・デモ目的で実トラフィックがなく、`cron` で定期実行しても意味のある
  データの変化が貯まらない。issue #297 本文は「scheduled workflow」と書いているが、これは
  #237 の実装（`workflow_dispatch` のみ）を指して書かれたものと解釈し、その実装に合わせる。
- `docs/metrics/scorecard/<YYYY-MM>.md` に月次スナップショットを追記。
- **`chore/scorecard-snapshot-<date>-<run_id>` ブランチへ push し、job summary に compare
  リンクを出す**（`main` へ直接 push しない・GitHub Actions によるPR自動作成が本リポジトリでは
  無効化されているため）。DORA 側で #247/#248 として実際に踏んで直った不具合
  （main直接push不可・PR自動作成失敗）を、最初から同じ形で回避する。

### 4. 可視化は「過去スナップショットからのスコア推移テーブル」

`docs/metrics/scorecard/*.md` の過去スナップショットから Golden Path/IDP スコアを正規表現で
抽出し、月次のスコア推移テーブルを毎回の出力に追記する（`render_trend`）。SVG バッジ等の
追加インフラは要らない ---
DORA の「4週移動平均」と同じ「Markdown テーブルで十分」という判断を踏襲する。

## Consequences

- **良い面**: DORA と同じ運用パターンなので学習コストが低く、`docs/metrics/` 配下の運用が統一
  される。ドリフト検知（宣言スコアの陳腐化）という、当初の issue には無かった副次的な価値が
  実装過程で得られた。
- **コスト**: 10 軸すべてを機械チェックしているわけではない（level4 ゲートが定義できる軸のみ）。
  レベル5や、定性的な判断が本質的な軸（例: ドキュメントの一本化の質）は、引き続き人間が
  catalog.json を更新する必要がある。
- **再検討トリガー**: DORA 側で real traffic が発生し `schedule` を有効化する判断（#237/
  ADR-0006 の再検討トリガー）が起きた場合、同じタイミングでスコアカードも `schedule` 化を
  検討する。`--strict` を実際に CI ゲートとして使いたくなった場合は、そのタイミングで
  ci.yml へのフック方法を別途検討する。
