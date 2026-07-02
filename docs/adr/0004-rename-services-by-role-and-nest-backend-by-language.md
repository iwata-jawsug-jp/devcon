# ADR-0004: `services/api`→`services/backend/python`、`services/web`→`services/frontend` へ改名する

- **Status:** Accepted
- **Date:** 2026-07-02
- **Deciders:** itouhi
- **Related:** #98, [提案書（PR #97）](https://github.com/iwata-jawsug-jp/devcon/pull/97),
  [実装（PR #99）](https://github.com/iwata-jawsug-jp/devcon/pull/99),
  [ADR-0003](0003-keep-monorepo-through-domain-and-authn-expansion.md)

## Context

[ADR-0003](0003-keep-monorepo-through-domain-and-authn-expansion.md) は `services/api` /
`services/web` / `infra` の3分割モノレポを維持する決定をしたが、`api`/`web` という命名は
実装物の呼称であり役割（バックエンド/フロントエンド）を表していない。加えて、将来
Python 以外の言語でバックエンドサービスを追加する可能性に備え、バックエンドを開発言語ごとに
サブフォルダで分けておきたいという要望があった。

## Decision

**サービス境界（3分割・単一 ECS Fargate）は変更せず、命名とディレクトリ階層のみを変更する。**

- `services/web` → `services/frontend`
- `services/api` → `services/backend/python`（`backend/` 配下を言語別サブフォルダにし、
  将来 `services/backend/go/` のように並置できるようにする）
- Python パッケージ内部名（`src/api/`、`from api.xxx import`、`uvicorn api.main:app`）は
  **変更しない**。ディレクトリの深さとパッケージ名は独立した概念であり、変更差分とリスクを
  最小化するため。
- npm パッケージ名は `"web"` → `"frontend"` に変更する。
- Makefile ターゲット名は `api-*`/`web-*` → `backend-*`/`frontend-*` にリネームする。
- Terraform（`infra/*.tf`）の AWS リソース名・タグ（ECR/ECS/S3 の論理名 `api`/`web`）は
  **変更しない**。`services/` のディレクトリ構成とは独立した AWS 側の命名であり、
  追従させるとリソースの再作成（replace）を招くため。

詳細な影響範囲調査・移行手順は [提案書](https://github.com/iwata-jawsug-jp/devcon/pull/97) と
[issue #98](https://github.com/iwata-jawsug-jp/devcon/issues/98) を参照。

## Consequences

- **良い面:** ディレクトリ名がサービスの役割を表すようになり、将来 Python 以外の言語で
  バックエンドを追加する際の置き場所（`services/backend/<言語>/`）があらかじめ決まっている。
  Python パッケージ名・Terraform リソース名を変更しなかったため、実装差分は
  パス参照の追従のみに収まり、AWS リソースの再作成も発生しなかった。
- **将来の負担（今は許容）:**
  - `services/backend/python/` の内部パッケージ名は `api` のままであり、ディレクトリ名
    （`backend/python`）とパッケージ名（`api`）が一致しない非対称性が残る。将来
    紛らわしさが問題になった場合は、内部 import を含めた別リネームを検討する余地がある。
  - Terraform の `aws_ecr_repository.api` 等のリソース名は `services/` のディレクトリ名と
    もはや対応しないため、コード上のパスとインフラ上の論理名の対応関係はコメント
    （`docs/infrastructure.md`）で補う必要がある。
- **再検討トリガー:** 2つ目以降の言語でバックエンドサービスを実際に追加するとき、
  `services/backend/<言語>/` という構成が想定通り機能するかを確認する。うまく機能しない
  場合は本 ADR を見直す。
