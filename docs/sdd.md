# 仕様駆動開発（SDD）ワークフロー

このリポジトリで、上流工程（業務整理 → 要件定義 → 基本設計）を成果物として残すための運用。
ツールは **cc-sdd**（Kiro 互換の Spec-Driven Development）を `--claude-skills` 方式で導入している。
導入の経緯・採否判断は [proposal/sdd-tooling-proposal.md](proposal/sdd-tooling-proposal.md) と
[adr/0002-adopt-spec-driven-development-with-cc-sdd.md](adr/0002-adopt-spec-driven-development-with-cc-sdd.md)
を参照。**どの変更に SDD を適用するか**の線引きは [`../CONTRIBUTING.md`](../CONTRIBUTING.md) を正とする。

## ディレクトリ構成

| パス                        | 役割                                                                              | 追跡                        |
| --------------------------- | --------------------------------------------------------------------------------- | --------------------------- |
| `.claude/skills/kiro-*/`    | cc-sdd のスキル本体（`SKILL.md` ＋ `rules/`）。`/kiro-*` で起動                   | コミットする                |
| `.kiro/settings/templates/` | steering / specs の雛形。**チームの開発プロセスに合わせて編集**してよい           | コミットする                |
| `.kiro/steering/`           | プロジェクト全体の知識（`product` / `tech` / `structure`）。AI に常時効かせる前提 | コミットする                |
| `.kiro/specs/<feature>/`    | 機能ごとの作業領域（`requirements.md` / `design.md` / `tasks.md` / `spec.json`）  | コミットする                |
| `.cc-sdd.backup/`           | 再導入時の自動バックアップ                                                        | **gitignore**（追跡しない） |

`.kiro/specs/<feature>/` は**開発中の作業領域**、`docs/requirements/` `docs/design/` は**完了後の
確定版置き場**、という役割分担にする（「正は `docs/`」方針との整合は下記）。

## ワークフロー

cc-sdd のスキルを順に使う（skills 方式のため slash command ではなく **Skill 起動**）。

1. **業務整理（任意・既存プロジェクトでは推奨）**: `/kiro-steering` で `.kiro/steering/` を生成・更新。
   横断的な規約は `/kiro-steering-custom <topic>`。
2. **要件定義**: `/kiro-spec-init "<作るもの>"` → `/kiro-spec-requirements <feature>`。
   requirements は **EARS 形式**（When/If/While/Where + shall）で受入条件を明確にする。
   既存コードベースへの追加なら `/kiro-validate-gap <feature>` でギャップ確認。
3. **基本設計**: `/kiro-spec-design <feature>`。API 契約・データモデル・ファイル構成・必要なら
   Mermaid 図（→ [design/README.md](design/README.md) の図表方針）。`/kiro-validate-design` で設計レビュー。
4. **タスク分解**: `/kiro-spec-tasks <feature>`。`tasks.md` を [issues.md](issues.md) の
   「1 issue → 1 focused PR・CI green」へ落とす。
5. **進捗確認**: `/kiro-spec-status <feature>`（任意のタイミングで）。
6. **実装 → 統合検証**: タスク単位で実装（下記「実装フェーズの運用規約」）。全タスク完了後に
   `/kiro-validate-impl <feature>` で機能横断の統合検証（GO / NO-GO）を行ってから昇格へ進む。

> 小さな変更に全工程を被せない。軽量な単一 spec は `/kiro-spec-quick`、即興の相談は Plan Mode
> （`/plan`）で十分（適用基準は CONTRIBUTING.md）。

## 実装フェーズの運用規約

EC デモ演習（Epic #159）の統合検証で実際に起きた問題（#211 / #212 / #213）に基づく規約。

### 帳簿はマージ・クローズと同じ手で更新する（#211）

`tasks.md` のチェックボックスと `spec.json` は「実装の実態」を映す帳簿であり、
`/kiro-validate-impl` は「全タスクが `[x]`」を成功基準とする。ズレたまま進むと検証時に
帳簿修正から始めることになる（演習では全 21 タスク完了後も 26 件が `[ ]` のままだった）。

- **PR のマージを確認して issue をクローズするとき、同じ手で `tasks.md` の該当タスクを
  `[x]` にする**（クローズと帳簿更新を別の作業にしない）。
- 統合検証が GO になったら `spec.json` の `phase` を `implementation-complete` に更新する
  （昇格後の spec が「完了済みの履歴」であることを machine-readable に残す）。

### design ドリフトは wave 完了時に検出する（#212）

個別タスクのレビューは「タスク定義との整合」を見るが、「design の網羅項目が実装群全体で
カバーされたか」は誰も見ない構造になりやすい（演習では design のエラーコード限定リスト
5 種のうち 2 種が未実装のまま統合検証まで残った）。

- **wave（並列実装のグループ）完了ごと、または統合タスクの完了条件として**、design の
  「列挙型の網羅項目」（エラーコード・ステータス値・API 契約表など）と実装を突き合わせる。
- design が実装より広いと分かったら、**「実装する」か「design を刈り込む」かを即時に選ぶ**
  （放置すると統合検証まで誰も気づかない）。
- `/kiro-spec-tasks` で列挙項目を該当タスクの完了条件へ転記しておくと、この突き合わせが
  タスクレビューに前倒しできる。

### 非機能・クロスカッティング要件は「締めるタスク」を明示する（#213）

「全画面で a11y 検査」「応答 1 秒」のような横断要件は、各タスクが部分的に触るだけで
全体を締める担当が生まれない（演習では requirements 45 基準中、PARTIAL になった 3 件が
すべてこの型だった）。

- タスク分解時に、**非機能要件ごとに「最後に締めるタスク」を 1 つ明示**し、その完了条件に
  対象の全数リストと検証手段（例: axe 対象画面の一覧との突き合わせ、実測ゲートの有無）を書く。
- 受け入れ基準を書く時点で「**計測可能か・どのゲートで検証するか**」を添える。検証手段が
  最後まで決まらない基準は、タスク分解時に「実測ゲートは持たない」と明示的に判断する。

### 完了条件には「境界を跨ぐ観察」を入れる（演習の最重要知見）

単体テストが green でも、トランザクション・プロセス・レイヤの境界を跨いだ瞬間に壊れる
バグは完了条件でしか捕まえられない。演習では「409 の後に**別セッションで**在庫を読んで
不変を確認する」という完了条件が、基盤層の UoW 潜在バグ（rollback されないトランザク
ション）を統合前に検出した。タスクの完了条件を書くときは、**境界を 1 つ跨いだ観察を
最低 1 つ**含める。

## 確定版への昇格（`.kiro/specs/` → `docs/`）

機能がリリースされたら、`.kiro/specs/<feature>/` の確定した成果物を `docs/` の保管庫へ移す。

1. `requirements.md` → [`docs/requirements/`](requirements/) に `<feature>.md` として配置。
2. `design.md` → [`docs/design/`](design/) に `<feature>.md` として配置。
3. インフラ・アーキ上の重要判断が含まれるなら、その「なぜ」を [`docs/adr/`](adr/) に ADR として残す。
4. `.kiro/specs/<feature>/` は履歴として残してよい（`spec.json` の `phase` で完了が分かる）。

これにより「**正（確定版）は `docs/`、作業中は `.kiro/`**」が成立し、`docs/` 一本化の方針
（[ai-instructions.md](ai-instructions.md)）と矛盾しない。

## CLAUDE.md を cc-sdd に所有させない

cc-sdd の導入/更新（`npx cc-sdd@latest --claude-skills ...`）は、ルート `CLAUDE.md` を自分の
ワークフロー説明で**丸ごと上書きしようとする**。本リポジトリの `CLAUDE.md` は厳選＋Copilot ミラー
管理下にあるため、**cc-sdd に CLAUDE.md を所有させない**。

- 再導入・更新時は `--overwrite skip`（非 TTY では自動 skip）＋ `--backup` を付け、`CLAUDE.md` は
  当方版を維持する（誤って上書きされたら `git checkout -- CLAUDE.md` で復元）。
- SDD への導線は、`CLAUDE.md`「More detail」からこの `docs/sdd.md` への**薄いポインタ 1 行**だけに
  留める（詳細はこの doc が正）。

## 公開ミラー・Copilot との関係

- **公開ミラー**: `.claude/skills/kiro-*` と `.kiro/`（settings / steering / 提示できる specs）は
  公開リポジトリ（`iwata-jawsug-jp/devcon`）にそのまま出してよい（SDD ワークフローの実例として
  価値がある）。**生煮えの作業中 spec をコミットしたまま Release しない**こと。除外が必要になった
  場合のみ release.md の除外リストに追加する。
- **Copilot ミラー対象外**: SDD 成果物（`.kiro/`）は「**何を作るか**」であり、実装規約
  （`CLAUDE.md` / `.github/instructions/*` ＝「**どう書くか**」）とは役割が異なる。両者を混同せず、
  `.kiro/` を Copilot instructions のミラー対象にはしない（[ai-instructions.md](ai-instructions.md)）。
  これはあくまで `.kiro/` の成果物の話であり、次節の `.claude/skills/kiro-*` 自体の話ではない。

## GitHub Copilot CLI からの利用

`.claude/skills/kiro-*` は Claude Code 専用ではない。GitHub Copilot CLI はプロジェクトスキルとして
`.github/skills` / `.claude/skills` / `.agents/skills` の 3 箇所を**追加設定なしにそのままスキャンする**
（[公式ドキュメント](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills)）。
実機（`copilot skill list`）でも `.claude/skills/kiro-*` 17 個が Project skills として認識されることを
確認済み。したがって **Copilot 向けの別ディレクトリ・ミラーは作らない**。cc-sdd の再導入・更新時も
本 doc の「CLAUDE.md を cc-sdd に所有させない」節と同じ運用（`--overwrite skip` ＋ `--backup`）を
維持すれば、Copilot 側も自動的に追従する。

### 既知の非互換点

- **`allowed-tools` は Copilot 側で解釈されない。** 各 `SKILL.md` の `allowed-tools`（`Bash` /
  `Agent` / `AskUserQuestion` / `MultiEdit` 等）は Claude Code 固有のツール名で、Copilot CLI は
  これを見ない。Copilot 側で同等の効果を得るには、起動時に Copilot 自身のツール種別名
  （`read` / `glob` / `grep` / `write` / `shell(cmd:*)`）で `--allow-tool` を指定する。
  **`read` に加えて `glob` / `grep` を明示的に許可しないと、探索が不十分になり誤った（ハルシネートした）
  レポートが返ることを実機確認済み**（単なる確認プロンプト増ではなく実害がある）。cc-sdd 側の
  `allowed-tools` はこの非互換を理由に手で書き換えない（次回の cc-sdd 再導入で上書きされ消えるため）。
- **`Agent`（サブエージェント並列実行）は Copilot 側に存在しない。** `kiro-impl` / `kiro-spec-design` /
  `kiro-spec-tasks` / `kiro-spec-batch` / `kiro-discovery` / `kiro-validate-impl` は `allowed-tools` に
  `Agent` を含み、Claude Code では並列サブエージェント実行を前提にした指示を持つ。Copilot CLI には
  同等の並列ディスパッチ機構がないが、実機確認（`kiro-validate-impl`）では **致命的エラーにはならず、
  単一エージェントとして逐次的に代替動作した**（未実装タスクを正しく検出して early-exit）。ただし
  `Agent` を前提にした重い分解・並列実装フロー（`kiro-spec-batch` 等）の品質・速度が Claude Code と
  同等かは未検証。実運用で気になる場合は都度確認すること。
- **`AskUserQuestion` の代替動作は未検証。** `kiro-spec-init` 等が使う構造化質問 UI は、Copilot 側では
  通常のテキスト質問にフォールバックすると推測されるが、実機での対話的検証はまだ行っていない。

## メンテナンス

- cc-sdd は更新の速い OSS。**四半期に一度**、`npx cc-sdd@latest --version` とコマンド/スキル体系の
  変更を確認する（ai-instructions.md のドリフト点検と同じ枠で実施）。このとき `copilot skill list`
  で `kiro-*` が引き続き認識されるかも合わせて軽く確認する（新規の別プロセスは作らず、この四半期
  点検に相乗りさせる）。
- `.kiro/settings/templates/` を自プロジェクト向けに育てると、生成される steering / spec の質が上がる。

## 関連ドキュメント

- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — SDD をどの変更に適用するかの基準（正）。
- [issues.md](issues.md) — tasks.md から実装への接続（1 issue 1 PR・CI green）。
- [design/README.md](design/README.md) — 基本設計の図表方針（Mermaid 基本）。
- [adr/](adr/) — 意思決定の記録。SDD 採用は [adr/0002](adr/0002-adopt-spec-driven-development-with-cc-sdd.md)。
- [proposal/sdd-tooling-proposal.md](proposal/sdd-tooling-proposal.md) — 導入提案書（背景・選択肢比較）。
