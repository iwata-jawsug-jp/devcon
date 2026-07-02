# 業務整理〜要件定義〜基本設計フェーズ ツール導入 提案書

**対象リポジトリ:** `iwata-jawsug-jp/devcon`（および個人 fork `iwata-jawsug-jp/devcon`）
**作成日:** 2026-07-01
**目的:** Dev Container + Claude Code 環境を、コーディング以前の「業務整理 → 要件定義 → 基本設計」フェーズでも効率よく使えるようにする。

---

## 1. 背景・目的

本リポジトリは `CLAUDE.md` 群・`.claude/settings.json`・`docs/`（詳細の正）という形で、**実装フェーズ**のガードレールは既に整っている（`docs/issues.md` に「issue から実装するときのフロー（1 issue 1 PR・CI green 確認）」も定義済み）。

一方で、その**上流工程**——「何を作るべきかの業務整理」「要件定義」「基本設計（アーキテクチャ・画面/API/DB設計）」——には、現状テンプレートも専用コマンドも存在しない。そのため新機能を追加するたびに、

- 要件のすり合わせが Issue の文章 or 口頭ベースで暗黙的に行われ、後から「なぜこの仕様か」が追えない
- 設計判断（特に Terraform 側のインフラ構成変更）が記録に残らず、属人化する
- AI（Claude Code）に実装を依頼する際の「曖昧な指示 → やり直し」が発生しやすい

という課題がある。本提案のゴールは、**業務整理・要件定義・基本設計を成果物として残しつつ、既存の Dev Container + Claude Code ワークフローにシームレスに接続すること**である。

---

## 2. 現状整理

| 既存資産                      | 内容                                                                      |
| ----------------------------- | ------------------------------------------------------------------------- |
| `.devcontainer/`              | Terraform / AWS CLI / Python / Node / Claude Code CLI をプリインストール  |
| `.claude/settings.json`       | チーム共有の権限設定（許可・確認・拒否コマンド）                          |
| `CLAUDE.md`（ルート＋ネスト） | アーキテクチャ・コマンド・規約。詳細は `docs/` を参照する薄い構成         |
| `docs/`                       | ルールの「正」を一本化（`app-development.md` / `infrastructure.md` など） |
| `docs/issues.md`              | **実装フェーズ**のフロー（1 issue 1 PR・CI green 確認）                   |
| `docs/proposal/`              | 提案書の置き場（前例：Copilot ルール化提案書）                            |

**欠けているもの：** 業務整理・要件定義・基本設計の成果物テンプレートと、それを Claude Code から起動する手段（スラッシュコマンド / スキル）。

---

## 3. 背景：2026 年の潮流（Spec-Driven Development）

2025 年の「vibe coding（雰囲気で AI に書かせる）」の反動として、2026 年は仕様を先に明文化してからAIに実装させる「仕様駆動開発（SDD: Spec-Driven Development）」が広まっており、GitHub・AWS・Anthropic・Cursor など大手が揃ってこの流儀のツールを提供している。

仕組みとしては、自然言語で書いた仕様書（spec.md）を起点に、AI コーディングエージェントが要件分解 → 設計 → タスク化 → 実装まで進める。「仕様書がそのまま設計ドキュメントになる」「仕様単位で分割すれば複数エージェントの並列実装もしやすい」という点が、Vibe Coding との大きな違いとされている。

本リポジトリは Claude Code が devcontainer に標準搭載されているため、この流れに乗せるのが最も投資対効果が高い。

---

## 4. 検討した選択肢

| 案                                 | 概要                                                                                       | 長所                                                                                                                                                                      | 短所                                                                                                           |
| ---------------------------------- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| **A. cc-sdd（推奨）**              | `npx cc-sdd@latest --claude --lang ja`。Kiro IDE の spec 形式と互換性のある OSS パッケージ | 日本語で要件・設計ドキュメントを出力可。`.claude/commands/` にスラッシュコマンドを自動展開し既存構成と統合しやすい。steering→requirements→design→tasks の定型フローを持つ | npm パッケージへの依存。Kiro 固有の概念（steering 等）を学ぶ必要がある                                         |
| B. GitHub Spec Kit                 | `specify` CLI。`/specify` `/clarify` `/plan` `/tasks` の定型コマンド群                     | GitHub 製 OSS で実績が多い。30 以上の AI エージェントに対応し、GitHub Actions（Issue 起点の `@claude /specify` 運用）とも親和性が高い                                     | 日本語テンプレートは自前での調整が必要。エージェント非依存ゆえ Claude Code 固有機能（Skills 等）との統合は薄め |
| C. Claude Code 標準 Plan Mode のみ | 追加導入せず `/plan` のみで都度設計を相談                                                  | 追加導入コストゼロ。小さな変更にはこれで十分                                                                                                                              | 成果物がドキュメント化・型化されず、後から参照しづらい。属人化のリスクが残る                                   |
| D. AWS Kiro（IDE）                 | AWS 製のスペック駆動 AI IDE                                                                | UI も含めて統合された体験                                                                                                                                                 | 別 IDE の導入が必要で、既存の VS Code + devcontainer + Claude Code 構成から離れる。課金体系も別                |

---

## 5. 推奨方針

**案 A（cc-sdd）を小機能 1 件で試験導入し、定着すれば本運用。合わなければ案 B（Spec Kit）に切り替える** という段階的なアプローチを推奨する。

理由：

- 既に `.claude/` ディレクトリと `CLAUDE.md` ベースの運用が確立しており、cc-sdd の `.claude/commands/` 展開方式が最も自然に乗る。
- `--lang ja` で日本語の要件・設計ドキュメントを直接生成でき、コミュニティ（JAWS-UG Iwata）向けの説明可能性が高い。
- 大きな投資をする前に、まず 1 機能で「業務整理 → 要件定義 → 基本設計 → 実装」の一周を体験し、ワークフローとして合うかを見極められる。
- 合わなかった場合も、Spec Kit は仕様書（spec.md / plan.md / tasks.md）という形式自体は共通点が多く、移行コストは大きくない。

C（Plan Mode のみ）は、ちょっとした修正や小さい変更には今後も使い続けてよい。**全ての変更に SDD のフルプロセスを被せる必要はない**（後述「留意点」参照）。

D（Kiro IDE）は、既存の devcontainer 中心の開発スタイルから外れるため、現時点では見送る。

---

## 6. 推奨ディレクトリ構成

```
devcon/
├── .claude/
│   └── commands/                  # cc-sdd が展開するスラッシュコマンド
├── .kiro/
│   ├── steering/                  # 業務整理（プロダクト原則・対象業務）
│   └── specs/
│       └── <feature-name>/
│           ├── requirements.md    # 要件定義
│           ├── design.md          # 基本設計
│           └── tasks.md           # タスク分解（実装フェーズへの橋渡し）
├── docs/
│   ├── requirements/              # 確定した要件定義の保管庫（任意）
│   ├── design/                    # 確定した基本設計の保管庫（任意）
│   ├── adr/                       # Architecture Decision Record（新規）
│   └── issues.md                  # 既存：実装フェーズのフロー
└── CLAUDE.md
```

- `.kiro/specs/<feature>/` は機能開発中の作業領域、`docs/requirements/` `docs/design/` は完了後の確定版置き場、という役割分担にすると、既存の「`docs/` を正とする」方針と矛盾しない。
- アーキテクチャ図は Markdown 内にそのまま Git 管理できる **Mermaid** を基本とする（GitHub 上でレンダリングされ、レビューしやすい）。AWS 構成図が複雑になる場合は Python 製の `diagrams` ライブラリや、AWS 公式アイコン入りの draw.io も選択肢。
- インフラ関連の意思決定（Terraform の構成変更など）は `docs/adr/` に ADR として残すと、後から「なぜこの構成にしたか」を追跡できる。

---

## 7. 運用フロー（案）

1. **業務整理（ステアリング）**：`/kiro:steering` または通常の Claude Code セッションで、プロダクト原則・対象業務を `.kiro/steering/` に言語化する。
2. **要件定義**：`/kiro:spec-init` → `/kiro:spec-requirements` で `requirements.md` を生成し、`[NEEDS CLARIFICATION]` 的な曖昧点を対話で潰す。
3. **基本設計**：`/kiro:spec-design`（または同等コマンド）で `design.md` を生成。API 契約・DB スキーマ・画面構成・AWS 構成を記述し、必要に応じて Mermaid 図を添える。
4. **タスク分解 → 実装へ接続**：`tasks.md` を `docs/issues.md` の「1 issue 1 PR」フローに落とし込み、既存の実装ガードレール（`CLAUDE.md` / `.claude/settings.json`）に引き継ぐ。
5. **確定後のアーカイブ**：機能がリリースされたら、`requirements.md` / `design.md` を `docs/requirements/` `docs/design/` に正式版として移す（`docs/ai-instructions.md` の「正は docs に一本化」方針を踏襲）。

---

## 8. 導入ステップ（ロードマップ）

1. **dry-run で影響範囲を確認**：`npx cc-sdd@latest --claude --lang ja --dry-run`
2. **試験導入**：実際に導入し、小さめの機能 1 件で `/kiro:steering` → `/kiro:spec-requirements` → `/kiro:spec-design` まで一周試す。
3. **ふりかえり**：cc-sdd のコマンド体系・生成ドキュメントの質が運用に合うか評価する。合わなければ B 案（Spec Kit）を同様に試す。
4. **`docs/ai-instructions.md` 方式の同期ルール整備**：`.kiro/` の成果物と `docs/` の確定版の対応関係、更新時の同期手順を明文化する（既存の CLAUDE.md ↔ docs 同期ルールと同じ考え方）。
5. **`CONTRIBUTING.md` に追記**：「新機能は `.kiro/specs/` での要件定義・基本設計を経てから実装に入る（軽微な修正は対象外）」という運用ルールを明記する。
6. **ADR 運用開始**：`docs/adr/0001-record-architecture-decisions.md` から開始し、インフラ・アーキテクチャ上の重要判断を記録する。

---

## 9. 留意点・既知の制約

- **仕様書を「書いてもらう」のではなく「書く補助をしてもらう」と捉える。** 曖昧な要件を投げれば曖昧な仕様しか出てこない。エンジニア側の言語化責任は変わらない。
- **すべての変更に SDD のフルプロセスを被せない。** 粒度の大きい新機能や、後で他人が読む必要がある変更にのみ適用し、軽微な修正は Plan Mode 程度で十分（過剰適用は「Waterfall の逆襲」になりがちと指摘されている）。
- **cc-sdd・Spec Kit ともに更新の早い OSS。** 四半期に一度程度、仕様・コマンド体系の変更を確認する運用が望ましい（`docs/ai-instructions.md` のドリフト点検と同様の運用でカバーできる）。
- **既存の Copilot 連携（`.github/instructions/*`）との二重管理に注意。** SDD ツールが生成する設計ドキュメントと、実装規約としての `CLAUDE.md`/Copilot instructions は役割が異なる（前者は「何を作るか」、後者は「どう書くか」）ため混同しない。

---

## 付録：基本設計フェーズの補助ツール一覧

| 用途                       | ツール                                      | 備考                                                           |
| -------------------------- | ------------------------------------------- | -------------------------------------------------------------- |
| アーキテクチャ図・フロー図 | Mermaid                                     | Markdown 内に直書きでき、GitHub 上でそのままレンダリングされる |
| AWS 構成図                 | Python `diagrams` / draw.io（AWS アイコン） | より精密な構成図が必要な場合                                   |
| 意思決定の記録             | ADR（`docs/adr/`）                          | Terraform 変更の多い本リポジトリと相性が良い                   |
| 要件定義・基本設計の生成   | cc-sdd（推奨） / GitHub Spec Kit            | 本提案のメイン論点                                             |
| 軽量な設計相談             | Claude Code Plan Mode（`/plan`）            | 小さな変更・即興的な相談向け                                   |
