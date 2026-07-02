# services/ モノレポ境界 整合性確認

**対象:** `services/api`（FastAPI）・`services/web`（Vite + Vue 3）
**作成日:** 2026-07-02
**結論:** 現行実装は [ADR-0003](../adr/0003-keep-monorepo-through-domain-and-authn-expansion.md)
（`services/api` / `services/web` / `infra` の3分割モノレポを維持する決定）と**完全に整合している**。
是正が必要な逸脱は見つからなかった。

---

## 1. 背景

README.md / docs/ の整合性確認に続き、`services/` 配下の実装がリポジトリのモノレポ方針（ADR-0003・
各サービスの `CLAUDE.md`）から逸脱していないかを確認した。

## 2. 確認観点と結果

| 観点                                                                                                                                         | 確認方法                                                                     | 結果                                                                                                |
| -------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| ADR-0003 の実装パターン（router + repository + schema + db-model をリソース単位で追加）                                                      | `services/api/src/api/{routers,repositories,schemas,db/models}` の構成を確認 | 一致。現状 `items` リソースのみで、ADR記載の想定通り                                                |
| ADR-0003 の単一 ECS Fargate サービス                                                                                                         | `infra/api.tf` の `aws_ecs_cluster` / `aws_ecs_service`                      | 一致。サービス分割なし、単一のまま                                                                  |
| サービス間のクロス依存禁止（api ⇔ web の直接参照なし）                                                                                       | `grep` で相互のパス参照を検索                                                | 該当なし                                                                                            |
| `services/api/CLAUDE.md`: routers に raw SQL を書かない・`Depends` 経由でリポジトリ利用・`response_model` 必須・Pydantic と ORM モデルの分離 | `routers/items.py` を読み込み確認                                            | 遵守。`RepoDep = Annotated[ItemRepository, Depends(get_repo)]` パターン、`response_model=` 設定済み |
| `services/web/CLAUDE.md`: API 呼び出しは `src/api/` の生成クライアント経由のみ、ad-hoc `fetch` 禁止                                          | `src/**/*.vue` / `*.ts` で `fetch(` を検索                                   | 該当なし（`src/api/client.ts` 経由のみ）                                                            |
| `ci.yml` のパスフィルタ分離（`services/api/**` / `services/web/**` / `infra/**` が独立ジョブ）                                               | `.github/workflows/ci.yml` の `changes` ジョブ定義                           | 一致                                                                                                |
| キャッシュ/ビルド成果物の非追跡（`.mypy_cache` / `.ruff_cache` / `.pytest_cache` / `coverage/` / `dist/` / `node_modules/` / `.venv/`）      | `git ls-files services/` で追跡ファイルを確認                                | 該当なし（`.gitignore` 通り未追跡）                                                                 |

## 3. 所見

- 現状の実装規模（`items` リソース1つのみ）は、ADR-0003 が「将来の負担」として挙げた
  再整理トリガー（リソース数がサブパッケージ化を要するほど増える、`infra/*.tf` がモジュール化を
  要するほど肥大化する）にまだ到達していない。
- 追加の対応は不要。次にドメインリソースを追加する際（Epic
  [#46](https://github.com/iwata-jawsug-jp/devcon/issues/46) の子タスク #40 等）も、本確認で検証した
  `items` と同じパターンを踏襲すればモノレポ境界は維持できる。
