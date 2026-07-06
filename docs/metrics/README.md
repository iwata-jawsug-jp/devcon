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

## 現状の注意点

このリポジトリはまだ infra 未適用のため `cd-app.yml` は `preflight` のみ成功し、実際のデプロイ
ジョブ（`deploy-api` / `frontend`）は skip されている（#145）。そのため、infra が適用され実際の
デプロイが始まるまではここに記録される値は 0 のままになる。これは意図した挙動であり、
スクリプトの不具合ではない。
