# フロントエンド複数フレームワーク比較デモ

学習・比較目的で、同じバックエンド API に対して複数のフロントエンドフレームワークで
同等の機能を実装し、並べて比較するための構成案。本番の `services/frontend/`（Vite + Vue 3、
`CLAUDE.md` 参照）はこの取り組みで一切変更しない。

> **現状: 計画のみ。** 本書は合意した構成方針を記録したもので、sandbox ブランチの作成・
> スキャフォールディング・恒久保持の可否判断はこれから行う（下記「今後の作業」参照）。

## 方針

sandbox.md の「恒久保持の例外（`sandbox/ec-site-demo`）」と同じ方式を踏襲する。

- **配置場所は専用の `sandbox/*` ブランチ**（例: `sandbox/frontend-frameworks-demo`）。
  `main` の `services/frontend/` には一切手を入れない — sandbox ブランチはそこから分岐した
  「別のリポジトリ状態」であり、ディレクトリ分離ではなくブランチ分離で本番から隔離する
  （`sandbox/ec-site-demo` が `services/frontend/` を EC デモ用に差し替えているのと同じ考え方）。
- ブランチ内のディレクトリ構成は `demos/frontend-frameworks/<framework>/`
  （例: `demos/frontend-frameworks/vue/`, `demos/frontend-frameworks/react/`,
  `demos/frontend-frameworks/svelte/`）。`services/` 配下に置かない — `services/` は
  「本番相当のサービス」を表す場所（ルート `CLAUDE.md` の Map 参照）であり、比較デモは
  本番サービスではないため区別する。
- **各フレームワーク実装は完全に独立したスキャフォールド**（自前の `package.json` /
  ビルド設定 / テスト / `CLAUDE.md`）。ロジック層（API クライアントのラップ方法や状態管理の
  抽象化）まで共通化しない — 各フレームワークの自然な書き方をそのまま比較できることが目的で、
  共通化するとその目的が薄れる。

## フレームワーク間で共有するもの / しないもの

| 対象                           | 扱い                                                                                                                                                                                          |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| バックエンド API の契約        | **共有。** 同一の `services/backend/python`（OpenAPI スキーマ）に対して各実装が独自にクライアントを生成する（`make gen-types` 相当をフレームワークごとに実行）。                              |
| デザイントークン               | **ソースを共有。** `docs/frontend-design.md` の front matter を正とし、各実装が自分のビルド方式に合わせてトークンを取り込む（Vue 実装の `main.css` 生成方式をそのまま流用するとは限らない）。 |
| 状態管理・API 呼び出しの抽象化 | **共有しない。** Pinia / TanStack Query 相当の選択はフレームワームごとに idiomatic なものを使う。                                                                                             |
| コンポーネント実装             | **共有しない。** 同じ画面・機能を各フレームワークでゼロから実装する。                                                                                                                         |
| E2E / Lighthouse などの計測    | 可能な範囲で同じシナリオ・同じ閾値を使い、フレームワーク間の比較軸を揃える（詳細は実装時に検討）。                                                                                            |

## 本番 `services/frontend/` との関係

- 本番は Vue 3 のまま変更しない。複数フレームワーク対応は本番の要件ではなく、あくまで
  比較・学習のためのサンドボックス活動。
- `sandbox/*` の隔離ポリシー（sandbox.md 参照）により、このブランチから
  `main` を含む非 `sandbox/*` ブランチへの PR/マージはできない。

## 今後の作業（未実施）

1. `sandbox/frontend-frameworks-demo` ブランチを作成し、`demos/frontend-frameworks/` 配下に
   最初のフレームワーク実装（Vue 移植 or 新規）を置く。
2. 恒久保持するか使い捨て（teardown 対象）にするかを決める。教材・参照用として残すなら
   `sandbox/ec-site-demo` が経た決定（[#217](https://github.com/iwata-jawsug-jp/devcon/issues/217)）
   と同様に、Issue で決定を記録し、削除禁止のブランチ保護ルールセットを追加する
   （[sandbox.md](sandbox.md#github-ルールセットsandbox-guard-を必須化) 参照）。
3. 進め方（Epic 化するか、ec-site-demo のように SDD 実践形式で進めるか等）を決める。

## 関連

  恒久保持例外
- [app-development.md](app-development.md) — `services/frontend/` の現行構成・規約
- [frontend-design.md](frontend-design.md) — デザイントークンの正
