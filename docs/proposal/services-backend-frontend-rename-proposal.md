# services/ ディレクトリ改名 提案書（`api`→`backend/<言語>`、`web`→`frontend`）

**対象:** `services/api` → `services/backend/python`、`services/web` → `services/frontend`
**作成日:** 2026-07-02
**ステータス:** 検討中（未決定）

---

## 1. 背景・目的

現状 `services/` 配下は `api`（バックエンド）・`web`（フロントエンド）という役割ではなく実装物の
呼称で命名されている。オーナーの意向は次の2点:

1. **役割ベースの命名にする**: `web` → `frontend`、`api` → `backend`。
2. **backend は開発言語ごとにフォルダーを分ける**: 将来 Python 以外の言語でバックエンドサービスを
   追加する可能性に備え、`services/backend/python/` のように言語名のサブフォルダを設ける。
   （将来 Go や Node 等を追加する場合は `services/backend/go/` のように並置する想定。）

[ADR-0003](../adr/0003-keep-monorepo-through-domain-and-authn-expansion.md) は
「`services/api` / `services/web` / `infra` の3分割モノレポを維持する」ことを決定した ADR であり、
本提案はそのサービス境界（3分割・単一 ECS Fargate）自体は変更せず、**命名とディレクトリ階層のみ**を
変更するもの。境界の変更ではないため ADR-0003 の決定を覆すものではないが、ADR が言及する具体的な
パス（`services/api`）が変わるため、採用する場合は軽量な追補 ADR（例: ADR-0004）での記録を推奨する
（`docs/adr/` の運用: 「infra/CI-CD/service boundary を変更したら ADR を追加する」）。

## 2. 提案する新構成

```
services/
├── backend/
│   └── python/          # 現 services/api の中身をそのまま移動
│       ├── src/api/     # Python パッケージ名 "api" は変更しない（後述）
│       ├── tests/
│       ├── alembic/
│       ├── pyproject.toml
│       └── Dockerfile
└── frontend/             # 現 services/web の中身をそのまま移動
    └── src/
```

## 3. 影響範囲（実際にリポジトリを調査した結果）

移動そのものは `git mv` で完結するが、パスをハードコードしている箇所の追従が必要。カテゴリ別に列挙する。

### 3.1 変更が必須（パスがハードコードされている）

| カテゴリ       | ファイル                                                                                                                | 内容                                                                                                                                                                            |
| -------------- | ----------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Makefile       | `Makefile`                                                                                                              | `API_DIR := services/api` / `WEB_DIR := services/web`（L6-7）を新パスに変更すれば `api-*`/`web-*` 系ターゲットは自動追従。コメント見出し（L81, L94）も追従                      |
| CI             | `.github/workflows/ci.yml`                                                                                              | `changes` ジョブのパスフィルタ（L32, L35）、`working-directory`（L47, L88）、`cache-dependency-path`（L96）                                                                     |
| CI (sandbox)   | `.github/workflows/ci-sandbox.yml`                                                                                      | 同様の `working-directory`（L23, L62）、`cache-dependency-path`（L70）                                                                                                          |
| CD             | `.github/workflows/cd-app.yml`                                                                                          | **Docker ビルドコンテキスト**（L52: `docker build ... services/api` → `services/backend/python`）、`working-directory`（L151）、`cache-dependency-path`（L159）                 |
| CD (sandbox)   | `.github/workflows/cd-app-sandbox.yml`                                                                                  | 同様（L54, L130, L138）                                                                                                                                                         |
| pre-commit     | `.pre-commit-config.yaml`                                                                                               | L45/L47 の `files: ^services/api/`、L55 の `exclude: ^(services/web/dist/\|...)` は**正規表現アンカー**。単純な文字列置換ミスでフックが静かに無効化されるリスクがあるため要注意 |
| gitignore      | `.gitignore`                                                                                                            | `services/web/dist/`・`openapi.json`・`playwright-report/`・`test-results/`・`.vite/`・`.lighthouseci/`（L62, L65-69）                                                          |
| gitignore      | `.prettierignore`                                                                                                       | `services/web/dist/`（L2）                                                                                                                                                      |
| CLAUDE.md      | ルート `CLAUDE.md`                                                                                                      | Map セクション（L27-28）と `services/api/CLAUDE.md` / `services/web/CLAUDE.md` への参照                                                                                         |
| CLAUDE.md      | `services/api/CLAUDE.md` → `services/backend/python/CLAUDE.md`                                                          | ファイル自体を移動、タイトル・自己参照パスを更新                                                                                                                                |
| CLAUDE.md      | `services/web/CLAUDE.md` → `services/frontend/CLAUDE.md`                                                                | 同上                                                                                                                                                                            |
| Copilot ミラー | `.github/copilot-instructions.md`                                                                                       | L8-9                                                                                                                                                                            |
| Copilot ミラー | `.github/instructions/backend.instructions.md`                                                                          | `applyTo: 'services/api/**'` → `'services/backend/python/**'`                                                                                                                   |
| Copilot ミラー | `.github/instructions/frontend.instructions.md`                                                                         | `applyTo: 'services/web/**'` → `'services/frontend/**'`                                                                                                                         |
| ドキュメント   | `docs/app-development.md`, `docs/development-environment.md`, `docs/ai-instructions.md`, `README.md`, `CONTRIBUTING.md` | 多数のプレーンテキスト参照（コマンド例・ツリー図・表）                                                                                                                          |
| Kiro steering  | `.kiro/steering/structure.md`, `.kiro/steering/tech.md`                                                                 | 構成説明のパス参照                                                                                                                                                              |

> `docs/ai-instructions.md` は「`CLAUDE.md` と Copilot `.github/instructions/*` は同じ PR で変更する」
> ことを明文の運用ルールとしているため、これは任意ではなく必須対応。

### 3.2 調査の結果、変更不要と確認できたもの

- **Terraform（`infra/*.tf`）**: `aws_ecr_repository.api` / `aws_ecs_service.api` / `aws_s3_bucket.web` /
  `aws_cloudfront_distribution.web` 等の `"api"`/`"web"` はすべて **AWS 側の論理名・タグ**であり
  `services/` ディレクトリのパスとは無関係。`infra/` 配下に `services/api`・`services/web` という
  パス文字列は一切出現しない。**Terraform の変更は不要**（むしろ AWS リソース名を追従させて
  変更すると ECR/ECS/S3 リソースの **replace（再作成）** を誘発しかねないため、意図的に触らない）。
- **`services/api/Dockerfile` 内部**: `COPY`/`WORKDIR` はすべてビルドコンテキスト相対のため、
  ディレクトリを深くしても Dockerfile 自体の編集は不要（CI 側のビルドコンテキスト指定のみ変更）。
- **Python パッケージ名 `api`**: `pyproject.toml` の `name = "api"` と
  `packages = ["src/api"]`、`alembic.ini` の `script_location`/`prepend_sys_path`（いずれも相対パス）は
  ディレクトリの深さと無関係。`services/backend/python/` に移動しても **`from api.xxx import` や
  `uvicorn api.main:app` の変更は一切不要**（後述 4.1 で意図的に維持する方針を提案）。
- **フロントエンドの `vite.config.ts` / `tsconfig.json` / `playwright.config.ts` / `lighthouserc.json`**:
  すべて自ファイル相対パスで完結しており、`services/web` のハードコードなし。
- **`.devcontainer/*`**: 参照なし。
- **`docker-compose.yml`**（ルート）: DB のみ定義しており `services/` への参照なし。
- **CODEOWNERS・Issue/PR テンプレート**: リポジトリに存在しないため対象外。

### 3.3 あえて変更しない（履歴として残す）

- `CHANGELOG.md` の過去エントリ、`docs/proposal/*.md`（本ドキュメントを含め過去の提案書）、
  `.kiro/specs/items-add-field/*`（完了済みスペックの記録）は**当時のパスをそのまま残す**。
  改名は新しい `CHANGELOG.md` の `[Unreleased]` エントリで記録する。
- `docs/adr/0003-...md` は決定当時の文脈の記録なので本文は書き換えず、採用時は追補 ADR
  （3.5 参照）で新パスを記録する。

## 4. 検討事項・意思決定が必要な点

### 4.1 Python パッケージ内部名（`src/api/` → そのまま `api` を維持するか）

- **提案: 維持する。** ディレクトリを `services/backend/python/` に移しても、内部の Python
  パッケージ名・import 文（`from api.routers import ...` 等）・Docker の起動コマンド
  （`uvicorn api.main:app`）は一切変更しない。パッケージ名とディレクトリの物理配置は独立した
  概念であり、変更差分・リスクを最小化できる。
- **代替案（不採用）**: `src/api/` も `src/backend/` にリネームし import 文もすべて追従させる。
  一貫性は上がるが、ルーター/リポジトリ/スキーマ/テスト/alembic の import を含む広範な差分になり、
  機能追加のない改名 PR としてはリスクとレビューコストに見合わない。

### 4.2 npm パッケージ名（`package.json` の `"name": "web"`）

- **提案: `"frontend"` に変更する。** 外部に公開されるパッケージではなく、ディレクトリ名との
  一貫性を取るコストが低いため。

### 4.3 Makefile ターゲット名（`api-*` / `web-*`）

- **提案: `backend-*` / `frontend-*` にリネームする。** `API_DIR`/`WEB_DIR` 変数だけ変えて
  ターゲット名を放置すると「`frontend-test` が `services/backend` のテストを指す」といった
  紛らわしさが残るため、ディレクトリ名と揃える。`make help` の表示も追従する。

### 4.4 Terraform ファイル名・AWS リソース名（`api.tf`/`web.tf`、ECR/ECS/S3 の論理名）

- **提案: 変更しない。** 3.2 の通り、`services/` のディレクトリ構成とは独立した AWS 側の命名。
  追従させると実リソースの再作成（ECR リポジトリ削除・S3 バケット作り直し等）を招くため、
  今回のスコープからは明確に除外する。

## 5. 移行手順（採用された場合）

1. `git mv services/web services/frontend`
2. `git mv services/api services/backend/python`（`git mv` が中間ディレクトリ `services/backend/` を
   自動生成する）
3. Makefile の `API_DIR`/`WEB_DIR` とターゲット名を更新
4. CI/CD ワークフロー（`ci.yml`, `ci-sandbox.yml`, `cd-app.yml`, `cd-app-sandbox.yml`）のパスフィルタ・
   `working-directory`・Docker ビルドコンテキスト・`cache-dependency-path` を更新
5. `.pre-commit-config.yaml` の正規表現アンカー、`.gitignore`、`.prettierignore` を更新
6. `CLAUDE.md`（ルート）、`services/backend/python/CLAUDE.md`、`services/frontend/CLAUDE.md` を更新
7. `.github/copilot-instructions.md`、`.github/instructions/{backend,frontend}.instructions.md` を
   同じ PR で更新（`docs/ai-instructions.md` の運用ルール）
8. `docs/app-development.md`、`docs/development-environment.md`、`docs/ai-instructions.md`、
   `README.md`、`CONTRIBUTING.md`、`.kiro/steering/{structure,tech}.md` のパス表記を更新
9. `npm` パッケージ名（`"web"` → `"frontend"`）を更新
10. `make lint` / `make test` / `make security` / CI をローカル・CI 双方で green 確認
11. `CHANGELOG.md` の `[Unreleased]` に改名を記録
12. 採用を確定した ADR（例: ADR-0004）を追加し、ADR-0003 からリンクする

各ステップは 1 PR にまとめず、`docs/issues.md` の「1 issue → 1 focused PR」方針に従い、少なくとも
「コード改名（1-5, 9-10）」と「ドキュメント/ADR（6-8, 11-12）」で分割することを推奨する
（CI が壊れた状態で分割PRを跨がないよう、コード改名側は 1 PR で CI green を確認してからマージする）。

## 6. リスク・注意点

- **`.pre-commit-config.yaml` の正規表現ミス**は「フックが静かに何も検査しなくなる」形で失敗するため、
  変更後に意図的にリンティング対象ファイルへ一時的な違反を仕込んで検知することを推奨。
- **Docker ビルドコンテキストの変更漏れ**は `cd-app.yml`/`cd-app-sandbox.yml` の両方に存在するため、
  片方だけ直して sandbox 側の CD が壊れる、という抜け漏れに注意。
- **`git mv` による履歴保全**: 通常の move + rename 検出で `git log --follow` は機能するが、
  同一 PR 内でファイル内容も変更すると rename 検出率が下がる場合がある。可能な限り「移動のみの
  コミット」→「パス文字列の中身を直すコミット」の2コミットに分けると差分レビューが容易になる。

## 7. 未決事項（この提案の承認前に確認したいこと）

- 将来追加予定のバックエンド言語の見込みはあるか（無ければ `services/backend/python/` の
  1段深いネストは過剰設計になる可能性がある。ただしオーナーの明示的な要望のため本提案では採用）。
- Terraform ファイル名 `api.tf`/`web.tf` は今回のスコープ外とするが、将来的にリソース名も
  含めて整理したい場合は別 ADR/提案として扱う。

## 8. 次のステップ

本提案の内容で GitHub issue を作成し、実装 PR に着手する（本ドキュメントは issue から参照する）。
