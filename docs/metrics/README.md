# DORA メトリクス（デプロイ頻度・変更リードタイム）

`.github/workflows/metrics-dora.yml` を手動実行（`workflow_dispatch`）すると集計し、このディレクトリに
月次スナップショット（`YYYY-MM.md`）として履歴を残す。定期（`schedule`）実行は無効化している
（この monorepo は学習・デモ目的で実トラフィックがなく、`cron` で定期実行しても意味のあるデータが
貯まらないため。本番運用のアプリで再有効化する手順は
[infrastructure.md](../infrastructure.md#定期実行ワークフローについてmetrics-dorayml--perfyml)参照）。
計測定義（デプロイイベント・リードタイムの判定ロジック）は
[ADR-0006](../adr/0006-dora-deployment-frequency-and-lead-time-definitions.md)を参照。

`main` は直接pushを受け付けない（`guard` ステータスチェック必須のリポジトリルール）ため、
スナップショットは `chore/dora-metrics-snapshot-<until>` ブランチへコミットのみ行う。このリポジ
トリは「GitHub Actionsによるプルリクエストの作成・承認」を無効化しているため、PR自体はワーク
フローが出す job summary 中のリンク（`compare/main...<branch>`）から手動で開く。他の変更と同様、
マージも手動で行う。

**実行頻度の目安**: スナップショットが月次ファイル（`YYYY-MM.md`）なので、月1回程度を目安に
手動実行する（厳密な期日はない。実行を忘れても実害はなく、次に実行したタイミングでその月の
ファイルに追記されるだけ）。カレンダーリマインダー等の自動化はまだしていない。

## 何が記録されるか

各スナップショットの区間ごとに次を記録する:

- **デプロイ回数**: backend（`deploy-api`）/ frontend（`frontend`）/ 合算（どちらか一方でも
  成功した run 数）
- **変更リードタイム**: そのデプロイに新たに含まれた PR の「最初のコミット → デプロイ完了」の
  中央値・p85・件数
- **直近4週間の移動平均**: 同じ指標を直近4週間分でならした参考値（週次ログの各エントリとは
  別集計。ISO週の境界で厳密に一致するとは限らない点に注意）

change failure rate / MTTR はここでは扱わない（#42 のアラーム整備・revert 運用の定義が前提。
[issue #237](https://github.com/iwata-jawsug-jp/devcon/issues/237) 参照）。しきい値・目標値も
当面設定せず、まず数ヶ月分のベースラインを観測する。

## 手動で集計する

Actions タブから `DORA Metrics` ワークフローを `Run workflow` で起動する（`since` / `until` を
指定すると任意期間を集計できる。省略時は直近7日間）。GitHub CLI からも:

```sh
gh workflow run metrics-dora.yml -f since=2026-06-01 -f until=2026-06-30
```

スクリプト単体をローカルで実行することもできる（`GITHUB_TOKEN` は read 権限があれば十分）:

```sh
GITHUB_TOKEN=$(gh auth token) python3 .github/scripts/dora_metrics.py \
  --owner itouhi --repo devcon --since 2026-06-01 --until 2026-06-30 --format markdown
```

## プラットフォーム成熟度スコアカード

`.github/workflows/metrics-scorecard.yml` を手動実行すると、
[`docs/metrics/scorecard-criteria.md`](scorecard-criteria.md) の10軸採点基準に基づき、
`docs/metrics/scorecard/catalog.json` の宣言スコアと機械信号（ファイル存在・grep によるパターン
検出）を突き合わせたスコアカードを生成し、このディレクトリの `scorecard/YYYY-MM.md` に月次
スナップショットとして履歴を残す。設計は
[ADR-0014](../adr/0014-platform-maturity-scorecard-automation.md) 参照。DORA と同じ理由で
`schedule` は使わず `workflow_dispatch` のみ、スナップショットは `chore/scorecard-snapshot-*`
ブランチへコミットのみ行う（PR は手動で開く）。

**実行頻度の目安**: DORA と同じく月1回程度を目安に手動実行する（厳密な期日はなく、実行忘れの
実害もない）。加えて、`docs/metrics/scorecard/catalog.json` の宣言スコアは自動更新されない
ため、大きな変更（新しい ADR・ゲート追加など）があった際は catalog.json も見直して
`last_reviewed` を更新する。

ローカルでも実行できる（stdlib のみ、依存インストール不要）:

```sh
python3 .github/scripts/scorecard_metrics.py
```

宣言スコアと機械信号が食い違う場合は `⚠️ 要確認` として出力される。`--strict` を付けると
不整合時に非ゼロ終了する。

**live-smoke 成功日時の確認（#376）**: 品質ゲート軸の `live_smoke_recent_success` チェックは、
`cd-app-sandbox.yml`/`cd-app.yml`/`cd-sandbox-cycle.yml` の `smoke-test` ジョブの実行履歴を
GitHub API で照会し、直近35日以内に成功した実行があるかを判定する（DORA と同じ urllib ベースの
API クライアントを流用、追加依存なし）。他のチェックと違い、リポジトリ内のファイルではなく
GitHub Actions の実行履歴を見る唯一のチェックのため、`GITHUB_TOKEN` と `GITHUB_REPOSITORY`
（Actions 実行時は自動設定）が必要。ローカルで確認する場合:

```sh
GITHUB_TOKEN=$(gh auth token) GITHUB_REPOSITORY=iwata-jawsug-jp/devcon \
  python3 .github/scripts/scorecard_metrics.py
```

`GITHUB_TOKEN`/`GITHUB_REPOSITORY` が無い場合はこのチェックのみ `NG` として報告されるが
（未実施の意味）、他のチェックには影響しない。既存の level4 ドリフト検知の対象（`gates`）にも
含めていないため、このチェック単独では宣言スコアとの不整合警告（⚠️）を発生させない。

## 現状の注意点

このリポジトリはまだ infra 未適用のため `cd-app.yml` は `preflight` のみ成功し、実際のデプロイ
ジョブ（`deploy-api` / `frontend`）は skip されている（#145）。そのため、infra が適用され実際の
デプロイが始まるまではここに記録される値は 0 のままになる。これは意図した挙動であり、
スクリプトの不具合ではない。
