# ADR-0008: 第4のゲート（実機E2Eスモーク）は Playwright Test プロジェクト + per-run 使い捨て Cognito ユーザーで実装する

- **Status:** Accepted
- **Date:** 2026-07-11
- **Deciders:** itouhi
- **Related:** #364, #373, #376

## Context

#364（golden path 実証の実機E2E検証）で見つかった #365（CSP）・#367（フロント環境変数未注入）・
#369（VPCエンドポイント欠如・バックエンド環境変数未注入）は、いずれも pre-commit / Makefile /
CI の既存3層ゲートでは原理的に検出不可能なクラスの欠陥だった。デプロイ環境の CSP・環境変数注入・
VPC 経路は、ローカル開発（Vite proxy）にも CI（認証をモックする単体/結合テスト）にも存在しない。

#373 で最小の対応として、`playwright` の `chromium.launch()` を直接叩く生スクリプト
（`services/frontend/scripts/smoke-test-sandbox.mjs`）を `cd-app-sandbox.yml` の post-deploy
ジョブとして追加し、固定の事前登録済み Cognito ユーザーでログイン → `GET /api/items` の 2xx を
確認する形で運用を開始した。CI デプロイロール（`ci_deploy`）が Cognito の `Admin*` ユーザー管理
権限を持たない設計だったため、テストユーザーは人が1回だけ手動登録し使い回す方式を採った。

#376 はこれを「第4のゲート」として定常化するにあたり、生スクリプト方式の3つの制約を挙げている:

1. Playwright Test runner の trace / screenshot / video 等の診断機能を持たない
   （失敗時の切り分けが困難）
2. 固定ユーザーは sandbox 環境を作り直す（apply し直す）たびに人手での再登録が必要
3. 既存の `npm run test:e2e`（`chromium` / `chromium-pwa` プロジェクト）と隔離された
   テスト資産として管理されていない

## Decision

**新しい `live-smoke` Playwright プロジェクト（`services/frontend/playwright.config.ts`）として
実装し、CI デプロイロールに新規付与する最小限の IAM 権限で per-run 使い捨て Cognito ユーザーを
使う。**

- 生スクリプトを廃止し、`services/frontend/e2e/live-smoke/` 配下に既存の `npm run test:e2e` と
  同じ Playwright Test runner ベースのテストを追加する。ログイン〜アクセストークン取得ロジック
  （アプリがトークンを `InMemoryWebStorage` にしか保持しないため、`localStorage`/
  `sessionStorage` 経由では読めず、OAuth2 トークン交換レスポンスを直接キャプチャする必要がある
  設計、#364 の検証スクリプトが最初に確立したもの）は `accessToken` fixture へ昇格し、
  S1〜S3 の各ステップは `test.step()` で構造化する。
- `trace: 'on'` / `screenshot: 'on'` / `video: 'on'` を常時有効にする。HAR は別途録集しない
  — Playwright の trace は既にネットワークログを含む（Trace Viewer の Network タブ）ため、
  追加の HAR 保存は冗長と判断した。
- 固定の事前登録済みユーザーを廃止し、`ci_deploy` ロールに `cognito-idp:AdminCreateUser` /
  `AdminSetUserPassword` / `AdminDeleteUser`（`infra/bootstrap/main.tf` の `ci_deploy_auth`、
  リソースは `arn:aws:cognito-idp:*:*:userpool/*` へスコープ — 具体的なプール ID は
  bootstrap 層より後に作られるアプリ層のリソースのため、この層からは参照できない。既存の
  ECS/ECR/RDS 系ステートメントと同じ「リソース種別までは絞るがアカウント/リージョンは
  ワイルドカード + `aws:RequestedRegion` 条件で絞る」パターンに合わせた）を新規付与し、
  ジョブ実行のたびに使い捨てユーザーを作成・削除する（パスワードは `openssl rand` 生成 +
  `::add-mask::`、非保存）。
- S1〜S3 のシナリオは issue #376 本文どおり: S1 = OIDC discovery → Hosted UI ログイン →
  トークン取得、S2 = 認証付き書き込み（`POST /api/items`、write scope を実際に検証。
  order-management 固有のエンドポイントは main に存在しないため、main/sandbox 両方で
  再利用できる既存の items API を使う）、S3 = 別ブラウザコンテキストからの整合性確認
  （`GET /api/items/{id}`、セッション分離・CloudFront ルーティングの退行を検出）。

### 却下した案

- **生スクリプトを維持したまま固定ユーザーだけ使い捨てに変える。** trace/screenshot 等の
  診断機能が無いまま失敗原因の切り分けコストを払い続けることになり、「第4のゲート」を
  定常運用する上で不利。
- **既存の `npm run test:e2e` プロジェクト（`chromium`）に相乗りする。** 既存プロジェクトは
  `webServer` でローカル Dev サーバー/ビルドプレビューを起動する前提であり、実デプロイ環境
  （`SMOKE_BASE_URL`）に向ける `live-smoke` とは起動条件が根本的に異なるため、独立プロジェクト
  として分離する（`SMOKE_BASE_URL` が設定されている間は `webServer` の起動自体をスキップする）。

## Consequences

- **良い面:** 失敗時に trace/screenshot/video が Actions artifact として残り、原因切り分けが
  速くなる。sandbox 環境を作り直すたびの手動ユーザー登録（`docs/sandbox.md` の旧手順）が
  不要になる。既存の Playwright 資産・規約（`e2e/home.spec.ts` 等と同じ書き方）と統一される。
- **受け入れるコスト:**
  - `ci_deploy` ロールに新たに Cognito ユーザー管理権限を付与する。`userpool/*` へスコープ
    済みだが、`infra/bootstrap/` は CI 外・人力適用の層（`docs/sandbox.md` 参照）のため、
    この変更は関連 PR マージ後に人が別途 `terraform apply` する必要がある。
  - S2 で作成した items テーブルの行を削除する API が存在しない（`DELETE /api/items/{id}`
    は未実装）ため、実行のたびにデータが蓄積する。`e2e-{run_id}` 等の識別可能な名前で
    作成するに留め、デプロイ頻度・週次サイクル程度の実行量であれば問題にならない規模と判断した。
- **再検討トリガー:**
  - items テーブルの蓄積行数が無視できない規模になった場合、DELETE エンドポイント追加、
    または別テーブル/フラグでのテストデータ識別を検討する。
  - #295（reusable workflow 化）が完了したら、`live-smoke` プロジェクトの CI 組み込み方法を
    reusable workflow 経由に寄せることを検討する（本 ADR の対象外）。
  - `cd-app.yml`（main）への展開（#376 PR③）・週次エフェメラルサイクル（#376 PR④）は
    本 ADR の対象外。この決定は PR①（本 ADR + `live-smoke` プロジェクト自体）と
    PR②（`cd-app-sandbox.yml` への組み込み + IAM 権限）のみを対象とする。
