# ADR-0006: DORA Four Keys のうちデプロイ頻度・変更リードタイムの計測定義

- **Status:** Accepted
- **Date:** 2026-07-04
- **Deciders:** itouhi
- **Related:** #237, [ADR-0001](0001-record-architecture-decisions.md)

## Context

プラットフォームエンジニアリング観点の評価（#153）で、ゲート強化や SDD 導入などの改善が
開発スループットに効いているかを検証する手段がなく、感覚に頼っているというギャップが
挙がった（#237）。DORA Four Keys のうち **deployment frequency** と **lead time for
changes** は、GitHub Actions / GitHub API のデータだけで追加インフラなしに算出できる。
change failure rate と MTTR は、アラーム整備（#42）と revert 運用の定義が前提となるため
本 ADR のスコープ外とし、後続で扱う。

計測の元データとなる `cd-app.yml` は次のジョブ構成を持つ:

```
preflight -> build -> migrate -> deploy-api   (backend)
          -> frontend                          (frontend)
```

`preflight` は app-layer のリポジトリ変数が未設定（infra 未適用）のときに `configured=false`
を出力し、`deploy-api` / `frontend` を含む後続ジョブを `if:` で明示的にスキップする（#145）。
スキップされたジョブは失敗扱いにならないため、ワークフロー run 全体は `success` のまま完了
する。したがって「run が `success` した」だけでは実際にデプロイが起きたかを判定できず、
デプロイの有無は **ジョブ単位の結論** を見る必要がある。

変更リードタイムは "commit → 本番稼働" までの時間を表す指標だが、GitHub API から機械的に
取得できるのは PR のコミット日時・merge 日時・ワークフロー run の日時であり、実際に
ユーザートラフィックを受け始めた瞬間ではない（`deploy-api` は ECS のロールアウト完了を
`services-stable` の wait で確認しているため、run 完了時刻は概ねロールアウト完了時刻に近い）。

## Decision

**デプロイイベント・変更リードタイムを次の通り定義する。**

### デプロイイベント

- 対象ワークフロー: `cd-app.yml`（`main` ブランチへの push トリガー、`workflow_dispatch` は
  手動再実行のため通常は集計対象に含めない）。
- 1 回のデプロイイベント = 対象 run において次のいずれかのジョブが `conclusion: success`
  になったこと。
  - `deploy-api` が `success` → **backend デプロイ** 1 件
  - `frontend` が `success` → **frontend デプロイ** 1 件
- `preflight` が `configured=false` を出し `deploy-api` / `frontend` が `skipped` に
  なった run はカウントしない（実際にはデプロイが起きていないため）。
- backend と frontend は **別々に計測**し、週次集計では両方の件数に加えて合算値（同一 run で
  どちらか一方でも成功していれば 1 件とする「デプロイが起きた run 数」）も併記する。理由:
  この2つは独立してデプロイされる別コンポーネントであり、どちらか一方だけを count すると
  頻度を過小評価する。一方で「リリースの脈動」を一目で見たい需要もあるため合算値も出す。

### 変更リードタイム

- 対象: 上記の定義でカウントされた各デプロイイベント（backend / frontend それぞれ）。
- 各デプロイイベントについて、そのデプロイで**新たに含まれることになった** merge 済み PR の
  集合を求める。「新たに含まれる」とは、同じジョブ種別（backend なら `deploy-api`、frontend
  なら `frontend`）の直前の成功イベント以降に `main` へ merge された PR のことを指す
  （直前の成功イベントがない場合は集計期間の開始時点を起点とする）。
- 個々の PR のリードタイム = そのデプロイ run の `completed_at` − PR の**最初のコミット**の
  日時（`GET /repos/{owner}/{repo}/pulls/{number}/commits` の先頭要素の
  `commit.author.date`）。
- PR のコミット履歴が API から取得できない・空である等の理由で最初のコミット日時が
  求まらない場合に限り、`merged_at` を代替の起点として使う（issue 本文が許容している
  近似）。この場合は集計結果にその旨を明示する。
- 1 件のデプロイイベントに複数 PR が含まれる場合、それぞれの PR のリードタイムを個別の
  データ点として扱う（デプロイ単位で 1 点に集約しない）。

### 集計単位

- ISO 週（月曜始まり）ごとに集計する。
- 各週について次を算出する:
  - デプロイ回数: backend / frontend / 合算（前述の定義）
  - 変更リードタイム: 中央値・p85（秒または時間単位）。母数（PR 件数）も併記する。
- 中央値と p85 を採用する理由: 単純平均は少数の長時間 PR（長期ブランチ・大型機能）に
  引っ張られやすく、"典型的な変更が本番に届くまでの時間" を表しにくい。中央値で典型値、
  p85 でロングテールの目安を見る。

### スコープ外（本 ADR では決めない）

- change failure rate、MTTR: #42（アラーム整備）の後続issue。
- しきい値・目標値の設定: 数ヶ月分のベースライン取得後に検討する（issue 本文の方針通り）。

## Consequences

- **良い面:** 追加インフラなしに GitHub API のみで2指標を機械的・再現可能に算出できる。
  backend/frontend を分けることで、どちらのコンポーネントの改善（またはボトルネック）かを
  区別できる。
- **受け入れるコスト:**
  - `workflow_dispatch` による手動再実行はデプロイイベントとして数えないため、手動運用が
    増えるとカバレッジが下がる。将来必要になれば `head_branch == 'main'` かつ
    `event in {push, workflow_dispatch}` を対象に広げる、といった見直しが要る。
  - リードタイムの起点はコミット日時であり、"要求が上がってから" のリードタイムではない
    （DORA の一般的な定義通り、実装着手〜本番稼働のみを見る）。
  - PR に紐付かない直接 push（通常運用では発生しない想定）は変更リードタイムの計算対象外
    になる。
- **再検討トリガー:**
  - `cd-app.yml` のジョブ構成（ジョブ名・依存関係）が変わったとき、本 ADR の判定ロジックを
    合わせて更新する。
  - 手動 `workflow_dispatch` によるデプロイが常態化し、無視できない割合になったとき。
  - change failure rate / MTTR の計測を始める際、本 ADR のデプロイイベント定義をそのまま
    再利用できるかを確認する。
