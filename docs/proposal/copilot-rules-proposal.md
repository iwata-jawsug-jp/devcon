# GitHub Copilot ルール化 提案書

**対象リポジトリ:** `iwata-jawsug-jp/devcon`
**作成日:** 2026-06-30
**目的:** 既存の `CLAUDE.md` 群で整備済みの開発ガードレールを、GitHub Copilot（Chat / coding agent / code review）にも効かせ、AI ツール非依存のルール基盤を整える。

---

## 1. 背景・目的

本リポジトリは Claude Code 向けに、ルート `CLAUDE.md` ＋エリア別のネスト `CLAUDE.md`（`services/api` / `services/web` / `infra`）で、アーキテクチャ・コマンド・「やってはいけないこと」を体系的に整備している。

一方、コミュニティのコントリビューターや自分自身が GitHub Copilot を使う場面では、これらのルールは**自動では効かない**。Copilot は `CLAUDE.md`（特にネストされたもの）を標準では読み込まないためである。結果として「Claude では守られるが Copilot では守られない」ルールのギャップが生じる。

本提案のゴールは次の状態を作ることにある。

- `CLAUDE.md` で表現済みの非自明なルールが、**Copilot のコード生成・コーディングエージェント・コードレビューでも効く**。
- ルールの実体（詳細）は `docs/` に一本化し、**二重メンテナンスのコストを最小化**する。
- 既存の `CLAUDE.md` 構造を壊さず、追加投資を抑える。

---

## 2. 現状整理（CLAUDE.md 構成）

| ファイル                 | スコープ       | 主な内容                                                                                                                                           |
| ------------------------ | -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CLAUDE.md`（ルート）    | リポジトリ全体 | Critical rules（main 直マージ禁止 / green-local=green-CI / 長期 AWS キー禁止 / シークレット禁止 / `--no-verify` 禁止）、Map、Run locally、Commands |
| `services/api/CLAUDE.md` | バックエンド   | uv 運用、async ルート、`response_model` 必須、生 SQL 禁止→repository 経由、Alembic 必須、型生成                                                    |
| `services/web/CLAUDE.md` | フロント       | `<script setup>`、`vue-tsc`（`tsc` 不可）、生成クライアント経由のみ、`VITE_` プレフィックスと機密境界                                              |
| `infra/CLAUDE.md`        | インフラ       | 2 層 Terraform、`tflint --recursive`、`default_tags`、リモート state、ローカル apply 禁止                                                          |

特徴として、各 `CLAUDE.md` は詳細を `docs/`（`app-development.md` / `infrastructure.md` 等）に委譲する**薄い参照型**になっている。この設計は本提案でそのまま活かせる。

---

## 3. GitHub Copilot のルール機構（2026-06 時点）

Copilot がリポジトリ固有ルールを読む仕組みは大きく 3 種類。

### (a) リポジトリ全体 — `.github/copilot-instructions.md`

リポジトリ直下に 1 枚置く全体ルール。Copilot のほぼ全面（IDE Chat / github.com Chat / coding agent / code review）で参照される。

### (b) パス別 — `.github/instructions/NAME.instructions.md`

フロントマターの `applyTo`（glob、カンマ区切り可）で適用範囲を絞る。**ネスト `CLAUDE.md` の概念に最も近い対応物**。

```markdown
---
applyTo: 'services/api/**'
---

（ここに当該パス向けのルール）
```

- `excludeAgent: "code-review"` 等で、特定エージェントに対してのみ無効化も可能（2025-11〜）。

### (c) `AGENTS.md`（ルート）

coding agent / Copilot CLI が参照する共通指示。`copilot-instructions.md` と併存可能（両方読まれる）。VS Code もリポジトリ指示として `AGENTS.md` を読む。

### 補足：CLAUDE.md の扱い

Copilot CLI はルートの `CLAUDE.md` / `GEMINI.md` を読めるが、**IDE の Chat・code review・coding agent は CLAUDE.md（特にネスト分）を読まない**。したがって、ルール内容を Copilot 用フォーマットに「橋渡し」する必要がある。

### 各機構が効く面（対応スコープ）

| ファイル                                            | IDE Chat | github.com Chat | coding agent |   code review   |
| --------------------------------------------------- | :------: | :-------------: | :----------: | :-------------: |
| `.github/copilot-instructions.md`                   |    ✓     |        ✓        |      ✓       |        ✓        |
| `.github/instructions/*.instructions.md`（applyTo） |    ✓     |        ✗        |      ✓       |        ✓        |
| `AGENTS.md`（ルート）                               |    ✓     |        △        |      ✓       |        △        |
| `CLAUDE.md`（ルート）                               |    ✗     |        ✗        |      ✗       | ✗（CLI のみ ✓） |

> 注：github.com の Chat ではパス別 instructions は未対応（coding agent / code review では有効）。仕様は流動的なため、導入後に PR の References 欄で実際に効いているか確認することを推奨。

---

## 4. 方針の選択肢と推奨

| 案                      | 構成                                                                         | 長所                                                          | 短所                                   |
| ----------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------- | -------------------------------------- |
| A. AGENTS.md 集約       | ルート `AGENTS.md` 1 枚                                                      | 最小手数                                                      | パス別の出し分け不可。ファイルが肥大化 |
| **B. ミラー型（推奨）** | `copilot-instructions.md` ＋ `instructions/*`（CLAUDE.md 構造を 1:1 ミラー） | ネスト CLAUDE.md と素直に対応。code review でも area 別に効く | CLAUDE.md と二重管理                   |
| C. ハイブリッド         | ルールは `instructions/*` に集約し、`AGENTS.md`/`CLAUDE.md` は薄いブリッジ   | 単一ソース化しやすい                                          | 構成がやや複雑                         |

**推奨は案 B（ミラー型）**。理由は、本リポジトリのネスト `CLAUDE.md` 構造が `applyTo` グロブにそのまま写像でき、移行コストが低いため。

### 二重管理問題への対処（重要）

案 B の唯一の弱点は `CLAUDE.md` と Copilot 用ファイルのドリフト。本リポジトリは既に**詳細を `docs/` に一本化**しているため、これを活かす。

- `copilot-instructions.md` と `*.instructions.md` も、詳細は書かず **`docs/` を参照**させる。
- 各ファイルに保持するのは「Copilot のコード生成・レビューで効く非自明ルール」のみに絞る。
- これにより、ルールの“正”は `docs/` の 1 箇所に保たれ、各 AI 向けファイルは薄い抽出に留まる。

---

## 5. 推奨ディレクトリ構成

```
devcon/
├── CLAUDE.md                          # 既存（変更なし）
├── docs/                              # 既存。ルールの「正」はここに集約
├── .github/
│   ├── copilot-instructions.md        # 新規：リポジトリ全体ルール
│   └── instructions/                  # 新規
│       ├── backend.instructions.md    #   applyTo: services/api/**
│       ├── frontend.instructions.md   #   applyTo: services/web/**
│       └── infra.instructions.md      #   applyTo: infra/**
└── services/ , infra/                 # 既存のネスト CLAUDE.md は残す
```

### CLAUDE.md ↔ Copilot ファイル マッピング

| CLAUDE.md                | Copilot 側                                      | applyTo           |
| ------------------------ | ----------------------------------------------- | ----------------- |
| `CLAUDE.md`（ルート）    | `.github/copilot-instructions.md`               | （全体）          |
| `services/api/CLAUDE.md` | `.github/instructions/backend.instructions.md`  | `services/api/**` |
| `services/web/CLAUDE.md` | `.github/instructions/frontend.instructions.md` | `services/web/**` |
| `infra/CLAUDE.md`        | `.github/instructions/infra.instructions.md`    | `infra/**`        |

---

## 6. ルール作成のベストプラクティス（Copilot 公式）

ドラフトは以下に従って作成している。

- **簡潔・単文**で書く（1 ルール 1 文）。冗長な散文は避ける。
- **理由（why）を添える**とエッジケースで判断が安定する（例：「`moment.js` は非推奨でバンドルが肥大化するため `date-fns` を使う」）。
- **linter / formatter が担保する規約は書かない**（ruff / prettier / tflint が見るものは省略）。
- **推奨パターンと回避パターン**を具体例で示す。
- 1 ファイルは**目安 4000 文字以内**。言語別ルールはパス別ファイルへ分離する。

---

## 7. 各ファイルのドラフト

そのままコミットできる初版。詳細は `docs/` 参照で薄く保っている。

### 7.1 `.github/copilot-instructions.md`

```markdown
# Copilot instructions — devcon

JAWS-UG Iwata の Web アプリ＋インフラの monorepo（Dev Container 前提）。
詳細は `docs/` と各 `.github/instructions/*.instructions.md` を参照。

## アーキテクチャ

- `services/api/` — バックエンド REST API（Python / FastAPI / uvicorn）
- `services/web/` — フロント SPA（TypeScript / Vite + Vue 3）
- `infra/` — Terraform IaC（AWS, ap-northeast-1）
- `web` は静的 SPA、`api` はステートレス JSON API。ブラウザは `/api/*` 経由でのみ
  `api` を呼び、AWS を直接叩かない。
- API 契約は FastAPI の OpenAPI スキーマ（`/openapi.json`）が唯一の正。フロントの型は
  `make gen-types` で生成する。手書きで二重に定義しない。

## 必ず守るルール

- **`main` へ直接マージしない。** PR は開いた状態にし、マージは人間が判断する。
- **シークレットをコミットしない。** `.env` / `*.tfvars` / 鍵は git 管理外。
  `*.example` テンプレートのみコミットする。
- **長期 AWS キーを作らない。** 認証は GitHub OIDC → ジョブ単位の IAM ロール。
  `AWS_ACCESS_KEY_ID` シークレットを追加しない。デプロイはローカルでなく CI で行う。
- **フロントの環境変数は `VITE_` プレフィックスかつ非機密**（ブラウザに出荷される）。
  バックエンドのシークレットはサーバ側（SSM / Secrets Manager）に置く。
- **`--no-verify` で pre-commit フックを迂回しない。**
- 「ローカルで green」は「CI で green」と一致させる。lint は CI と同じコマンドで
  実行する（例：`tflint --recursive`）。

## コマンド

ルートの `Makefile` を優先（`make help`）：
`make dev` / `make fmt` / `make lint` / `make test` / `make security` / `make gen-types`。
```

### 7.2 `.github/instructions/backend.instructions.md`

```markdown
---
applyTo: 'services/api/**'
---

# Backend（Python / FastAPI）

詳細: `docs/app-development.md`、`services/api/CLAUDE.md`。

- Python の実行は必ず `uv run`。素の `python` / `pip` を使わない。
- ルートハンドラは async。依存は `Depends` で注入する。
- リクエスト/レスポンス両方を Pydantic モデルで検証し `response_model=` を設定する。
  生 dict を返さない。ルートは `/api` プレフィックス配下。
- ハンドラ/ルータに生 SQL を書かない。`Depends(get_session)` で `AsyncSession` を取り、
  repository 経由で参照する（責務分離のため）。
- スキーマ変更は必ず Alembic マイグレーション（`make makemigration`）。DB を手で変更しない。
  ORM モデルと Pydantic モデルは分離する（レスポンスは `from_attributes=True`）。
- 型ヒントを維持する（mypy strict）。
- 設定は `API_` プレフィックスの環境変数から取得する。バックエンドのシークレットは
  サーバ側（SSM / Secrets Manager）に置き、コミットしない。
- リクエスト/レスポンスの形を変えたら `make gen-types` で TS クライアントを再生成する。
  型を二重に手書きしない。
```

### 7.3 `.github/instructions/frontend.instructions.md`

```markdown
---
applyTo: 'services/web/**'
---

# Frontend（TypeScript / Vite + Vue 3）

詳細: `docs/app-development.md`、`services/web/CLAUDE.md`。

- SFC は `<script setup lang="ts">`（Composition API、strict、ESM）。
- 型チェックは `vue-tsc --noEmit` を使う。`tsc` は使わない（Vue の型を解決できないため）。
- API 呼び出しは `src/api/` の生成クライアント経由のみ。コンポーネント内で素の `fetch`
  を書かない。
- `src/api/schema.ts` は OpenAPI から `make gen-types` で生成。手で編集しない。
  API 契約変更後は再生成してコミットする。
- フロントの環境変数は `VITE_` プレフィックスかつ非機密（ブラウザに出荷される）。
  シークレットをフロントに置かない。
```

### 7.4 `.github/instructions/infra.instructions.md`

```markdown
---
applyTo: 'infra/**'
---

# Infra（Terraform / AWS）

詳細: `docs/infrastructure.md`、`infra/CLAUDE.md`。

- リソースのタグは provider の `default_tags` で付与する。個別リソースに手でタグを付けない。
- lint は CI と同じ `tflint --recursive` で確認する（`bootstrap/` も走査される）。
  `make tf-lint` だけでは CI green の保証にならない。
- state はリモート（S3 + native locking）。`*.tfstate` をコミットしない。
- 設定は `env/*.tfvars` / `*.backend.hcl`（git 管理外）。`*.example` テンプレートのみ
  コミットする。シークレットをコミットしない。
- ローカルで `terraform apply` / `destroy` やイメージ push をしない。app-infra の変更は
  `cd-infra.yml`（main マージ時、`production` Environment でゲート）が担う。
- 認証は GitHub OIDC → ジョブ単位の IAM ロール。`AWS_ACCESS_KEY_ID` シークレットを
  追加しない。
- `bootstrap/` はローカル state で一度だけ apply するレイヤで、`cd-infra.yml` の管理外。
```

---

## 8. 導入ステップ（ロードマップ）

1. **ファイル追加**：上記 4 ファイルを 1 つの PR で追加（`docs/` 参照型で薄く）。
2. **動作確認**：適当な PR を作り、Copilot Chat / code review の References 欄に
   各 instructions が出ているか確認。`applyTo` のグロブが意図通りか検証する。
3. **code review 有効化**：リポジトリ設定で Copilot code review を有効化し、area 別の
   フィードバックが出るか確認。
4. **運用ルール化**：`CONTRIBUTING.md` に「ルールを変えたら `docs/` を正として更新し、
   `CLAUDE.md` と `.github/instructions/*` の両方に反映する」旨を追記。
5. **（任意）`excludeAgent` 活用**：レビュー特化ルール／生成特化ルールを出し分けたく
   なったら導入する。

---

## 9. 留意点・既知の制約

- Copilot の指示適用は**非決定的**。競合する指示は避ける（公式も非推奨）。
- 優先順位は Personal > Repository > Organization。すべて読まれるが矛盾は避ける。
- github.com の Chat では**パス別 instructions が未対応**（coding agent / code review では有効）。
  全面で確実に効かせたいルールは `copilot-instructions.md` 側に置く。
- `CLAUDE.md` と Copilot 用ファイルの同期は残課題。詳細を `docs/` に一本化することで
  ドリフトを最小化するが、ゼロにはならない。PR レビューで両者の整合を見る運用を推奨。
- 仕様は更新が速い領域。導入後も四半期に一度程度、公式ドキュメントで機構の差分を確認する。

---

## 付録：Copilot 用ファイルに「載せない」もの

以下は `CLAUDE.md` にはあるが、Copilot 用ファイルでは省略・要約してよい（コード生成では
効きにくい、または linter/CI が担保するため）。

- `make help` の全コマンド列挙 → 主要なものだけ。
- formatter / linter が機械的に直す整形ルール（インデント幅など）。
- 詳細なディレクトリ構造の説明 → `docs/` 参照に委譲。
