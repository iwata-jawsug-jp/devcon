# ADR-0002: 上流工程に SDD（cc-sdd skills 方式）を採用する

- **Status:** Accepted
- **Date:** 2026-06-30
- **Deciders:** itouhi
- **Related:** [Epic #66](https://github.com/iwata-jawsug-jp/devcon/issues/66), #60, #61, #62, [ADR-0001](0001-record-architecture-decisions.md), [docs/sdd.md](../sdd.md)

## Context

実装フェーズのガードレール（`CLAUDE.md` 群 / `.claude/settings.json` / `docs/`）は整っていたが、
その上流工程（業務整理 → 要件定義 → 基本設計）にはテンプレートも専用手段も無く、要件が暗黙化・
設計判断が属人化していた（提案書 §1）。2026 年の SDD
（Spec-Driven Development）の潮流に乗せ、devcontainer 標準搭載の Claude Code を活かすのが投資対効果が
高い。提案書では案 A（cc-sdd）/ 案 B（GitHub Spec Kit）/ 案 C（Plan Mode のみ）/ 案 D（Kiro IDE）を
比較し、段階的導入（まず cc-sdd を小機能 1 件で試験導入）を推奨していた。

## Decision

**cc-sdd を `--claude-skills` 方式で採用する。**

- 検証（#60 dry-run・#61 PoC）の結果、生成物の質・日本語出力・既存フロー（1 issue 1 PR・CI green）
  との接続性が実用水準と確認できたため、案 A を本採用する。
- **方式は skills（`--claude-skills`）**。提案書が前提にしていた `--claude`（commands）方式は
  cc-sdd v3.0.2 で DEPRECATED になったため、推奨される skills 方式を採る（`.claude/skills/kiro-*`）。
- 運用の正は [docs/sdd.md](../sdd.md)。ディレクトリ構成・昇格手順・保護ルールはそこで定義する。
- 案 C（Plan Mode）は軽微な変更で併用を継続。全変更に SDD のフルプロセスは被せない。

### 採用に伴う制約（docs/sdd.md で恒久化）

1. **`CLAUDE.md` を cc-sdd に所有させない。** 導入/更新は `--overwrite skip` ＋ `--backup` で行い、
   当方の厳選 `CLAUDE.md` を維持する。SDD 導線は `CLAUDE.md` から `docs/sdd.md` への薄いポインタのみ。
2. **`.kiro/` と `.claude/skills` はコミット**し、`.cc-sdd.backup/` のみ gitignore。
3. **役割分離**: `.kiro/`（何を作るか）は Copilot 実装規約ミラー（どう書くか）の対象外。
4. **四半期点検**: 更新の速い OSS のため、コマンド/スキル体系の変更を定期確認する。

## Consequences

- **良い面:** 要件・設計が成果物として残り、コミュニティへの説明可能性が上がる。`tasks.md` が
  既存の実装フローへ素直に接続する。意思決定（本 ADR 含む）が追跡可能になる。
- **コスト:** `.claude/skills`（17 スキル）＋ `.kiro/settings`（テンプレ）のフットプリント増。
  必要なら `--profile minimal` やスキル剪定で軽量化を検討する（将来の最適化）。
- **再検討トリガー:** cc-sdd が運用に合わなくなった場合は、提案書 §5 のとおり案 B（GitHub Spec Kit）
  への切替を別 ADR で検討する。spec.md / design.md / tasks.md という成果物の形式は共通点が多く、
  移行コストは限定的。
