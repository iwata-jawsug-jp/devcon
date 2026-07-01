# AI 開発ルールの同期手順

このリポジトリは、開発ガードレール（アーキテクチャ・コマンド・「やってはいけないこと」）を
**複数の AI ツール向けファイルにミラー**している。本書はそれらを**ドリフトさせないための
同期手順**をまとめる。ルール本文の規約自体は各ファイルと [`../CLAUDE.md`](../CLAUDE.md) を参照。

## ルールの「正」は `docs/`

二重メンテナンスのコストを最小化するため、**ルールの詳細（正）は `docs/` に一本化**する。
`CLAUDE.md` 群と `.github` の Copilot 用ファイルは、いずれも詳細を書かず **`docs/` を参照する
薄い抽出**に留める。AI 向けファイルに載せるのは「コード生成・レビューで効く非自明ルール」のみ。

## ファイル対応表

| ルール本文の正                 | Claude Code              | GitHub Copilot                                  | スコープ          |
| ------------------------------ | ------------------------ | ----------------------------------------------- | ----------------- |
| `docs/app-development.md` ほか | `CLAUDE.md`（ルート）    | `.github/copilot-instructions.md`               | リポジトリ全体    |
| `docs/app-development.md`      | `services/api/CLAUDE.md` | `.github/instructions/backend.instructions.md`  | `services/api/**` |
| `docs/app-development.md`      | `services/web/CLAUDE.md` | `.github/instructions/frontend.instructions.md` | `services/web/**` |
| `docs/infrastructure.md`       | `infra/CLAUDE.md`        | `.github/instructions/infra.instructions.md`    | `infra/**`        |

- Claude Code はルート ＋ ネストの `CLAUDE.md` を読む。Copilot（IDE Chat / coding agent /
  code review）は `CLAUDE.md` を読まないため、同じ内容を `.github` 側に橋渡しする。
- Copilot 側のパス別ファイルは frontmatter の `applyTo`（glob）で適用範囲を絞る。値は上表の
  スコープ列と一致させる。
- **`CLAUDE.md` も Copilot 用ファイルも英語で書く。**1:1 で行単位の diff 照合ができ、
  ドリフト検出が容易になる（トークン効率もわずかに有利）。

## 同期手順（ルールを変えるとき）

1. **`docs/` を更新する。**ルールの実体（正）はここ。まず正を直す。
2. **対応する `CLAUDE.md` を更新する。**ルート全体ルールならルート、領域固有ならネスト分。
3. **対応する Copilot 用ファイルを更新する。**上の対応表で同じ行のファイルへ反映。スコープが
   変わるなら `applyTo` も合わせる。
4. **1 つの PR にまとめる。**「正（docs）＋ 両 AI 向けファイル」を同じ PR で変更し、レビューで
   三者の整合を確認する。`Closes #<issue>` を付ける。
5. **フォーマットを通す。**Markdown は pre-commit と同じ prettier が走る（`*.md` 対象）。
   `--no-verify` でフックを迂回しない。

> 1 ファイルだけ直して他を放置しない。**docs / CLAUDE.md / Copilot の 3 点セットで動かす**のが
> 唯一の同期不変条件。

## ドリフト点検

- 対応表の同じ行の `CLAUDE.md` と `*.instructions.md` を **diff で照合**する（同一英語表現に
  揃えてあるため、意味差はほぼ行差として現れる）。
- PR レビュー時、ルール変更が「正（docs）」「Claude 側」「Copilot 側」の三者に反映されているか
  をチェックリストとして確認する。
- 仕様は流動的な領域のため、導入後も四半期に一度程度、Copilot 公式ドキュメントで機構（`applyTo`
  対応面・`excludeAgent` 等）の差分を確認する。

## 既知の制約

- Copilot の指示適用は**非決定的**。`CLAUDE.md` と矛盾する指示は書かない。
- github.com の Chat は**パス別 instructions が未対応**（coding agent / code review では有効）。
  全面で確実に効かせたいルールは `.github/copilot-instructions.md` 側に置く。
- 詳細を `docs/` に一本化してもドリフトはゼロにはならない。上記の「3 点セット PR」運用で抑える。
- **SDD 成果物（`.kiro/`）はこのミラーの対象外**。`.kiro/`（要件・設計＝「何を作るか」）と、この
  対応表が扱う実装規約（`CLAUDE.md` / `*.instructions.md` ＝「どう書くか」）は役割が異なる。混同して
  `.kiro/` を Copilot instructions に取り込まない。SDD の運用は [sdd.md](sdd.md) が正。
- **`.claude/skills/kiro-*` はこの表の対象外（ミラー不要で両ツールから直接使える）**。`.kiro/` と
  違い、GitHub Copilot CLI は `.claude/skills` を追加設定なしにそのままスキャンするため、Claude Code
  と Copilot CLI が同じファイルを直接共有する。frontmatter（`allowed-tools` 等）の一部フィールドは
  Copilot 側で解釈されないなどの非互換はあるが、それは「別ファイルとして同期する」話ではないため
  対応表には載せない。詳細・既知の非互換点は [sdd.md](sdd.md) を参照。

## 関連ドキュメント

- [`../CLAUDE.md`](../CLAUDE.md) — アーキテクチャと規約の正（Claude Code 向け）。
- [app-development.md](app-development.md) / [infrastructure.md](infrastructure.md) — ルール本文の詳細。
- [issues.md](issues.md) — issue から実装するときのフロー（1 issue 1 PR・CI green 確認）。
- [sdd.md](sdd.md) — 上流工程の SDD ワークフロー（`.kiro/` は実装規約ミラーと役割が別）。
- 導入の経緯・方針比較は [proposal/copilot-rules-proposal.md](proposal/copilot-rules-proposal.md)。
