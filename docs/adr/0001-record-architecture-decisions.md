# ADR-0001: アーキテクチャ上の意思決定を ADR として記録する

- **Status:** Accepted
- **Date:** 2026-06-30
- **Deciders:** itouhi
- **Related:** #63, [Epic #66](https://github.com/iwata-jawsug-jp/devcon/issues/66), [docs/proposal/sdd-tooling-proposal.md](../proposal/sdd-tooling-proposal.md)

## Context

本リポジトリは Terraform による IaC を中核に持ち、インフラ構成の変更（state ロック方式・
OIDC によるキーレス CD・承認ゲートの方式変更など）が頻繁に発生する。一方で「なぜその構成に
したか」の判断根拠は、これまで issue / PR の議論や `CHANGELOG.md` に断片的に残るだけで、
**まとまった一次情報として追跡できなかった**。結果として、

- 設計判断が属人化し、後から「なぜこの構成か」を再構築するのに時間がかかる
- 一度却下した案が、却下理由を忘れて再浮上する
- 上流工程（業務整理 → 要件定義 → 基本設計）を整備する SDD 導入（Epic #66）と歩調を
  合わせて、設計判断の置き場を確立したい

という課題がある。

## Decision

**アーキテクチャ・インフラ上の重要な意思決定を ADR（Architecture Decision Record）として
`docs/adr/` に記録する。**

- フォーマットは [Michael Nygard 方式](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)
  を基本とし、[`template.md`](template.md)（Status / Context / Decision / Consequences）を使う。
- ファイル名は `NNNN-kebab-case-title.md`（連番ゼロ詰め 4 桁）。
- 一度 Accepted にした ADR は**書き換えず**、覆す場合は新しい ADR を起こして旧 ADR の
  Status を `Superseded by ADR-XXXX` に更新する（決定の履歴を残す）。
- この「ADR を使うという決定」そのものを最初の ADR（本 ADR-0001）とする。

### いつ ADR を書くか

「どう書くか」の実装規約は `CLAUDE.md` / `docs/` の責務であり、ADR の対象外。ADR は
**「何を・なぜそう決めたか」**の意思決定を残す。次のような場合に書く:

- インフラ構成の変更（Terraform のリソース構成・state 管理・ネットワーク/権限境界）
- CI/CD パイプラインの方式変更（認証方式・承認ゲート・デプロイ戦略）
- アーキテクチャの分割方針（サービス境界・データ永続化・契約の置き方）
- 容易に覆せない / 後から他人が前提を知る必要がある技術選定

軽微な変更や容易に戻せる実装判断には不要（提案書 §9「過剰適用を避ける」と同じ精神）。

## Consequences

- **良い面:** 設計判断の根拠が一次情報として残り、属人化と「却下案の再浮上」を抑制できる。
  SDD（Epic #66）の `design.md` から ADR を参照する形で、上流工程の成果物と接続できる。
- **コスト:** 重要判断のたびに ADR を 1 本書く運用負担が増える。閾値（上記「いつ書くか」）で
  過剰適用を防ぐ。
- **更新運用:** ADR は追記型。覆すときは新 ADR ＋ 旧 ADR の Status 更新で履歴を残す。

## 遡って ADR 化する候補（backlog）

既に確定済みだが根拠を残す価値のある判断。優先度順に個別 ADR として起票していく（本 ADR の
スコープ外・别 PR）:

- [ ] Terraform 2 層構成（`infra/bootstrap/` ＋ アプリ層、リモート state / 部分 backend） — `docs/infrastructure.md`
- [ ] GitHub OIDC による**キーレス CD**（長期 AWS キーを持たず、ジョブ単位の IAM ロール引受）
- [ ] state ロックを DynamoDB → **S3 ネイティブロック**（`use_lockfile`）へ移行（CHANGELOG 0.0.3）
- [ ] `apply` を main push 自動実行から**手動 `workflow_dispatch`** に変更した承認ゲート（CHANGELOG 0.0.6）
- [ ] web=静的 SPA / api=ステートレス JSON の**プロセス分離**と CloudFront 経路設計
