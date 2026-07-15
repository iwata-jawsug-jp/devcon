# ADR-0013: awslabs/aidlc-workflows の全面採用を見送る

- **Status:** Accepted
- **Date:** 2026-07-15
- **Deciders:** itouhi
- **Related:** #470, [ADR-0002](0002-adopt-spec-driven-development-with-cc-sdd.md),
  [ADR-0010](0010-adopt-copier-for-scaffold-cli.md),
  [ADR-0011](0011-scaffold-template-in-place.md), [ai-instructions.md](../ai-instructions.md),
  [sdd.md](../sdd.md)

## Context

#470 で、AWS が公開する [awslabs/aidlc-workflows](https://github.com/awslabs/aidlc-workflows)
（AI-DLC: AI-Driven Development Life Cycle、MIT-0、3,500+ stars）のルール・スキルをこのモノレポに
取り込むかどうかを、(1) フォルダー構成と `CLAUDE.md` の扱い、(2) 取り込みサイクルと方法、
(3) ライセンス、の 3 観点で検討した。

調査で確認した事実:

- **配布形態**: `aidlc-rules/aws-aidlc-rules/core-workflow.md`（コアワークフロー、単一ファイル
  約 25KB）と `aidlc-rules/aws-aidlc-rule-details/`（詳細ルール、`common/inception/construction/
extensions/operations` 配下に約 30 ファイル・計 270KB 超）を GitHub Releases の zip
  （`ai-dlc-rules-v<version>.zip`）で配布。`aidlc-rules/VERSION`（現行 1.0.1）・`CHANGELOG.md`
  （git-cliff 生成）・`tag-on-merge.yml`/`release.yml` により、約月 1 回ペースでバージョン管理された
  リリースが継続的に出ている（v0.1.5〜v1.0.1、2026-02〜06）。
- **公式の Claude Code 導入手順**（README "Version Control Recommendations" / "Claude Code" 節）は、
  `core-workflow.md` を**そのまま `./CLAUDE.md` に上書きコピー**する方式（Option 1: Project Root
  (Recommended)）。「既存の `CLAUDE.md` に追記する」手順は提供されていない。同時に新規トップレベル
  ディレクトリ `.aidlc-rule-details/` が追加される。
- **ワークフローの性質**: チャットで「Using AI-DLC, ...」と宣言すると起動し、
  INCEPTION（要件・設計）→ CONSTRUCTION（実装）→ OPERATIONS（運用、future）の 3 段階を、構造化された
  質問ファイル・実行計画の承認ゲートを介して進め、成果物を `aidlc-docs/` に生成する。security /
  testing / resiliency 等の extension（opt-in の追加ルール）機構も持つ。
- **付随ツール**: `scripts/aidlc-evaluator/`（AI-DLC 自体の変更検証用）、
  `scripts/aidlc-designreview/`（Amazon Bedrock 経由の Claude モデルで設計成果物をレビューする
  実験的 CLI。**独自の MIT ライセンス・`NOTICE`** を持ち、Bedrock への依存を伴う別サブプロジェクト）。
  `aidlc-codereview` は既に別リポジトリ（`aws-samples/sample-aidlc-code-reviewer`）へ分離済み。
- **v2.0 が Preview 中**: README 冒頭で AI-DLC Workflows 2.0（`v2` ブランチ、専用仕様書 PDF あり）が
  Preview 告知されており、近い将来コアの仕様が変わる可能性が高い。
- **ライセンス**: `aidlc-rules/` は MIT-0（帰属表示不要）。本リポジトリは通常の MIT
  （著作権表示あり）。ライセンス条項上の非互換はなく、コピー・改変・再配布に法的障害はない。

これを、本リポジトリが既に確立している運用と突き合わせた:

- [`ai-instructions.md`](../ai-instructions.md) は「ルール本文の正は `docs/`、`CLAUDE.md`/Copilot
  側は薄い抽出」という一本化原則を定めている。
- [ADR-0002](0002-adopt-spec-driven-development-with-cc-sdd.md) は cc-sdd 採用時に、まさに同種のリスク
  （外部 SDD ツールが `CLAUDE.md` を生成物として上書きしようとする）に直面し、「**`CLAUDE.md` を
  cc-sdd に所有させない**（`--overwrite skip` ＋ `--backup` で導入し、厳選 `CLAUDE.md` を維持する）」
  という制約を明文化して採用した前例がある。
- cc-sdd（`.kiro/` + `.claude/skills/kiro-*`）は、要件定義 → 設計 → タスク分解という上流工程を
  既にこのリポジトリの標準として運用している。

## Decision

**awslabs/aidlc-workflows の全面採用（ルール一式の取り込み）を見送る。**

3 観点それぞれの結論:

1. **フォルダー構成と `CLAUDE.md` の扱い**: 公式手順が前提とする「`core-workflow.md` で
   `CLAUDE.md` を丸ごと置き換える」方式は、`ai-instructions.md` の一本化原則、および ADR-0002 が
   明文化した「`CLAUDE.md` を外部ツールに所有させない」制約と正面から矛盾する。`.aidlc-rule-details/`
   （270KB 超・30 ファイル）を追加すれば、`docs/` と並行するもう一つのルール階層ができ、
   ドリフト管理コストが増えるだけで一本化のメリットを損なう。
2. **取り込みサイクルと方法**: リリース管理自体は健全（GitHub Releases・`VERSION`・
   `CHANGELOG.md`・月 1 ペース）で、"バージョンを指定して追従する" という取り込み方式が技術的に
   成立する対象ではある。しかし 1. の構造的な衝突がある以上、追従の枠組みを整備する意味がない。
   加えて v2.0 が Preview 中で近く仕様が変わる可能性が高く、今 v1.0.1 を取り込んでも早期に作り直しが
   発生するタイミングリスクがある。
3. **ライセンス**: MIT-0 のため本リポジトリ（MIT）への組み込みに法的障害はない。帰属表示は不要だが、
   将来個別のアイデアを参考にする場合は取り込み元・バージョン・日付をコメントか ADR に残すのが望ましい。
   `scripts/aidlc-designreview/` 等の付随ツールは Bedrock 依存の別ライセンスサブプロジェクトであり、
   本検討（steering rules の取り込み）のスコープ外として評価対象から除外する。

加えて、AI-DLC の INCEPTION/CONSTRUCTION/OPERATIONS というフェーズゲート型・成果物生成型の
ワークフローは、既に採用済みの cc-sdd（ADR-0002）と機能的に重複する。両者を並行運用しても、
「どちらの方法論に従うべきか」という混乱コストの方が大きく、価値を生まない。

## Consequences

- **良い面**: 既存の `CLAUDE.md`/`docs/` ガバナンスと cc-sdd による SDD 運用を壊さずに済む。
  270KB 超のルール文書や Bedrock 依存の付随ツールなど、余分なフットプリントを抱えない。
- **コスト**: AI-DLC が持つ個別の工夫（例:
  `aidlc-rule-details/common/overconfidence-prevention.md` の「確信度が低い時は質問することを
  デフォルトにする」設計、`question-format-guide.md` の構造化質問フォーマット、
  `session-continuity.md` のセッション継続設計）を自動では取り込めない。必要が生じた時点で、
  個別に着想だけを手動で参考にする（一括インポートはしない）。
- **再検討トリガー**:
  - AI-DLC v2.0 が GA し、`CLAUDE.md` 全面所有ではなく既存ファイルへの追記・参照方式に変わった場合。
  - cc-sdd の運用に不満が生じ、SDD 方式自体を再検討する場合
    （[ADR-0002](0002-adopt-spec-driven-development-with-cc-sdd.md) の再検討トリガーと連動）。
  - `aws-aidlc-rule-details/` 配下の特定ルール（1 ファイル単位）を部分的に移植したい具体的なニーズが
    出た場合。その際は一括取り込みではなく、該当ファイルのみを個別 issue で検討する。
