# Research & Design Decisions

## Summary

- **Feature**: `authn-authz`
- **Discovery Scope**: Complex Integration（API・フロント・インフラの3層横断、外部IdP選定を伴う）
- **Key Findings**:
  - FastAPI 側の JWT 検証は `python-jose`（保守停止・脆弱性あり）ではなく **PyJWT**（`PyJWKClient`）が現在の推奨。FastAPI公式もこの方向に倣った。
  - Cognito のアクセストークンには `aud` が無く `client_id`／`token_use`／`scope` を見る必要がある（IDトークンと取り違えない）。
  - フロントは Amplify SDK ではなく **`oidc-client-ts`**（18KB gzip、Amplifyの1/2〜1/6）が本プロジェクトの軽量方針・バンドル予算に適合。
  - Cognito は Authorization Code + PKCE では Hosted UI が事実上必須（`InitiateAuth` はコードフローを発行できない）。カスタムドメイン未整備でも `*.cloudfront.net` の callback URL で問題なく動く。
  - SPA 単体（BFF無し）では httpOnly Cookie でのトークン保管ができない — アクセストークンはメモリ保持、リフレッシュトークンの扱いはトレードオフとして明示する必要がある。

## Research Log

### FastAPI での Cognito JWT 検証

- **Context**: Requirement 1（401判定）・Requirement 2（403判定）を実装可能な形にするための検証層の技術選定。
- **Sources Consulted**:
  - [PyJWT docs](https://pyjwt.readthedocs.io/en/latest/usage.html)
  - [fastapi/fastapi#11345](https://github.com/fastapi/fastapi/discussions/11345)（python-jose 非推奨化の経緯）
  - [PyJWKClient source](https://github.com/jpadilla/pyjwt/blob/master/jwt/jwks_client.py)
  - [AWS: Verifying JSON web tokens](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-tokens-verifying-a-jwt.html)
  - [FastAPI: OAuth2 scopes](https://fastapi.tiangolo.com/advanced/security/oauth2-scopes/)
  - [FastAPI: Testing Dependencies with Overrides](https://fastapi.tiangolo.com/advanced/testing-dependencies/)
- **Findings**:
  - `python-jose` は2021年以降更新が無く、依存する `ecdsa` に未修正の脆弱性がある。**PyJWT** の `PyJWKClient` を採用する。
  - `PyJWKClient` は JWKS全体のTTLキャッシュ（既定300秒）と、`kid` 単位のLRU鍵キャッシュ（`kid`未知時は自動再取得）を標準搭載 — 自前のTTLキャッシュ実装は不要。
  - 既知の制約（[pyjwt#1051](https://github.com/jpadilla/pyjwt/issues/1051)）: 失効した署名鍵がLRUキャッシュから即座には消えない場合がある。教材リポジトリとしては許容範囲のリスクとして記録する。
  - 認可（スコープ判定）は FastAPI の `Security()` + `SecurityScopes` が最も idiomatic。ミドルウェアやデコレータと異なり DI チェーンに合成でき、OpenAPI にも自動反映される。
  - Cognito のアクセストークンは `aud` を持たない（`client_id` を見る）。ID トークンと違い、API 認可には**アクセストークン**を使う。`token_use` クレームで種別を必ず検証する（IDトークンをアクセストークンとして再利用されない為）。
  - テストは `app.dependency_overrides` で `get_current_user` を差し替え、実際の Cognito/JWKS 呼び出し無しで 401/403/200 経路を検証する（FastAPI公式パターン、既存 `conftest.py` の `get_session` オーバーライドと同じ仕組み）。
- **Implications**: `services/backend/python/src/api/auth/` に JWKS 検証・`Security` ベースの依存関係を新設し、`items.py` の各エンドポイントに `Security(get_current_user, scopes=[...])` を付与する。

### Vue 3 SPA での認証方式

- **Context**: Requirement 3・4（ログイン/ログアウト/セッション失効時のUX）を、BFFを持たない静的SPAでどう実現するか。
- **Sources Consulted**:
  - [Cognito PKCE docs](https://docs.aws.amazon.com/cognito/latest/developerguide/using-pkce-in-authorization-code.html)
  - [Auth0: Token Storage](https://auth0.com/docs/secure/security-guidance/data-security/token-storage)
  - [Curity: Best Practices for Storing Access Tokens in the Browser](https://curity.medium.com/best-practices-for-storing-access-tokens-in-the-browser-6b3d515d9814)
  - [Vue Router: Navigation Guards](https://router.vuejs.org/guide/advanced/navigation-guards.html)
  - [Pinia: Core Concepts](https://pinia.vuejs.org/core-concepts/)
  - [authts/oidc-client-ts](https://github.com/authts/oidc-client-ts)
  - [AWS blog: Amplify JS v6 bundle size](https://aws.amazon.com/blogs/mobile/amplify-javascript-v6/)
  - [Amplify tree-shaking OAuth callback bug #14803](https://github.com/aws-amplify/amplify-js/issues/14803)
- **Findings**:
  - Implicit flow は非推奨（トークンがURLフラグメントに露出、リフレッシュ不可）。Authorization Code + PKCE を採用する。
  - 本プロジェクトはBFFを持たない静的SPA（S3+CloudFront）— httpOnly Cookie でのトークン保管は不可能。アクセストークンはメモリ保持のみとし、`localStorage`には置かない。リフレッシュトークンの永続化は明確なトレードオフとして残る（詳細は Design Decisions 参照）。
  - `router.beforeEach` + `meta.requiresAuth` は現在も Vue Router 4 の公式・最新の慣用パターン。変更不要。
  - Pinia は setup-store 構文がトークンのメモリ保持・リフレッシュタイマーとの相性が良い。
  - `oidc-client-ts`（18KB gzip、汎用OIDCクライアント）は、Amplify Auth（ベストケースでも31KB gzip、実際は tree-shaking 不全で120KB近いケースも報告あり・issue #14803のコールバック処理が誤って tree-shake される既知バグあり）より軽量かつ本プロジェクトの「薄い自前fetchクライアント」方針に合致する。
- **Implications**: `services/frontend/src/auth/` に `oidc-client-ts` の `UserManager` 設定と Pinia 認証ストアを新設。`src/api/client.ts` の唯一の `request()` に Authorization ヘッダー付与と401時のリフレッシュ処理を追加。

### AWS Cognito の Terraform 構成

- **Context**: Requirement 1〜5 を実現するために必要な最小限の Cognito リソースと、既存インフラ（ALB/ECS Fargate/CloudFront、カスタムドメイン未整備）との整合性確認。
- **Sources Consulted**:
  - [aws_cognito_user_pool_client docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cognito_user_pool_client)
  - [aws_cognito_user_pool_domain docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cognito_user_pool_domain)
  - [AWS Security Blog: Hosted UI or custom UI](https://aws.amazon.com/blogs/security/use-the-hosted-ui-or-create-a-custom-ui-in-amazon-cognito/)
  - [Amazon Cognito Pricing](https://aws.amazon.com/cognito/pricing/)
  - [Cognito feature plans — Plus](https://docs.aws.amazon.com/cognito/latest/developerguide/feature-plans-features-plus.html)
- **Findings**:
  - Authorization Code フローは Hosted UI 経由でしか発行できない（`InitiateAuth` はコード発行不可）ため、Hosted UI（`aws_cognito_user_pool_domain`）は事実上必須。
  - `aws_cognito_user_pool_client` は `generate_secret = false`（パブリッククライアント）とすることでPKCEが暗黙的に要求される。クライアントシークレットは一切発行されないため、Requirement 5（機密情報の非露出）は「シークレットが存在しない」ことで自動的に満たされる。
  - JWKS URL・`iss` はリージョン＋ユーザープールIDから決定的に導出できる（追加のTerraformリソース不要）。CognitoのHosted UIドメインは無料の `<prefix>.auth.<region>.amazoncognito.com` で足り、カスタムドメイン・ACM証明書は不要。`callback_urls` に既存の `*.cloudfront.net` を登録すれば動作する。
  - 2024年12月改定の料金体系で新規ユーザープールは既定で **Essentials** ティア（月10,000 MAU無料）。**Plus**（旧Advanced Security Features相当）はリスクベース認証等を提供するが無料枠が無く、教材用途では過剰。本designでは Essentials を採用する。
  - Cognito の認可情報はカスタムスコープ（Resource Server）または `cognito:groups` で表現できる。read/write の権限分離（Requirement 2）には、標準的なOAuth2スコープ機構である **Resource Server カスタムスコープ**（例: `api/items.read`, `api/items.write`）を採用する（グループはユーザー管理UIに近い概念で、今回の最小認可モデルには過剰）。
- **Implications**: `infra/auth.tf` に `aws_cognito_user_pool` / `aws_cognito_resource_server`（カスタムスコープ定義） / `aws_cognito_user_pool_client` / `aws_cognito_user_pool_domain` を追加。`infra/outputs.tf` に非機密の Cognito 識別子（user pool ID・client ID・ドメイン・リージョン）を出力する。

## Architecture Pattern Evaluation

| Option                                          | Description                                             | Strengths                                                        | Risks / Limitations                                                                                                      | Notes                                                                                            |
| ----------------------------------------------- | ------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| API層でJWT検証（採用）                          | FastAPI の `Security`/`Depends` でCognito発行JWTを検証  | JSON API向けの401/403を明確に返せる、ALBのTLS/リスナー変更が不要 | JWKS取得のレイテンシ（キャッシュで緩和）                                                                                 | 既存の `Depends` パターンに自然に合成できる                                                      |
| ALBリスナーの `authenticate-cognito` アクション | ALB自体がCognitoでリダイレクト認証                      | インフラのみで完結、アプリ変更最小                               | HTTPSリスナー+ACM証明書が前提（未整備）、JSON APIに不向き（Web画面向けのリダイレクトが前提で401/403の作り分けが困難）    | 却下。Requirement 1/2 の401/403契約と相性が悪い                                                  |
| 自前パスワード認証 + 自己発行JWT                | Cognito等を使わずAPI側でユーザーテーブル・JWT発行を自作 | 外部依存なし                                                     | パスワードハッシュ・保管・ローテーション等セキュリティ実装をゼロから作る必要があり、教材リポジトリとしてはリスクが大きい | 却下。要件定義でも技術選定は非依存としつつ、既存インフラ（AWS）を活かせるCognitoが最小実装コスト |

## Design Decisions

### Decision: JWT検証ライブラリに PyJWT を採用

- **Context**: Cognito発行JWTの署名・claims検証をFastAPI側で行う必要がある。
- **Alternatives Considered**:
  1. python-jose — 2021年以降未更新、依存ライブラリに未修正脆弱性
  2. authlib — OAuthクライアント/サーバーの汎用機能を含み、リソースサーバーとしての検証用途には過剰
- **Selected Approach**: PyJWT の `PyJWKClient` でJWKS取得・キャッシュ・署名検証を行い、`jwt.decode` で `aud`/`iss`/`exp`/`token_use` を検証する `get_current_user` 依存関数を実装。
- **Rationale**: 現在も活発にメンテナンスされ、FastAPI公式もこの方向に倣っている。JWKSキャッシュを自前実装しなくて済む。
- **Trade-offs**: `PyJWKClient` のLRU鍵キャッシュに厳密なTTLが無く、失効鍵が即座には破棄されない場合がある（pyjwt#1051）。
- **Follow-up**: 実装時にキャッシュlifespanの明示設定（既定300秒）を確認する。

### Decision: フロントのOIDCクライアントに oidc-client-ts を採用（Amplify不採用）

- **Context**: Cognito Hosted UI との Authorization Code + PKCE フローをVue3 SPAから扱う必要がある。
- **Alternatives Considered**:
  1. AWS Amplify（`aws-amplify/auth`） — Cognito公式SDK、ベストケースでも31KB gzip、実運用では tree-shaking 不全で120KB近い報告あり
  2. 自前でOAuth/PKCEフローを実装 — 車輪の再発明、セキュリティリスク
- **Selected Approach**: `oidc-client-ts` の `UserManager` を使用し、標準的なOIDC Authorization Code + PKCEフロー（state/nonce/code_verifier管理込み）を扱う。
- **Rationale**: 18KB gzipと軽量で、本プロジェクトの薄い自前`fetch`クライアント方針・既存バンドル予算（現状49.6KB/600KB）に合致する。汎用OIDCクライアントのため将来IdPを変更してもフロント実装への影響が小さい。
- **Trade-offs**: AmplifyのようなCognito特化の便利機能（自動リトライ等）は無く、Cognitoエンドポイントの設定は明示的に行う必要がある。
- **Follow-up**: 実装時に `oidc-client-ts` の最新安定版とVite/Rollupでのバンドル実測を確認する。

### Decision: アクセストークンはメモリ保持のみ、リフレッシュトークンはトレードオフとして明示

- **Context**: 本プロジェクトはBFFを持たない静的SPA。httpOnly Cookieでのトークン保管ができない制約下で、トークン保管方式を決める必要がある。
- **Alternatives Considered**:
  1. `localStorage` 保管 — 実装は単純だがXSS時に永続的に読み取られる、業界のベストプラクティスに反する
  2. `sessionStorage` 保管（タブスコープ） — `localStorage`よりは限定的だがXSS時の露出リスクは残る
  3. 最小限のBFF/エッジ関数を追加してhttpOnly Cookieを発行 — 最も安全だがこのspecのスコープを超えるインフラ追加になる
- **Selected Approach**: アクセストークンはメモリ（Pinia setup-storeの非永続state）のみに保持し、`localStorage`/`sessionStorage`には置かない。リフレッシュトークンも同様にメモリ保持とし、ページリロードでセッションが失われる（＝Requirement 4の再認証誘導で対応）ことを許容する。
- **Rationale**: 外部からの読み取りが可能な永続ストレージを避けることを優先する。ページリロードでの再ログインは、静的SPAという制約下での妥当なトレードオフ。
- **Trade-offs**: タブを閉じる/リロードのたびに再認証が必要になり、UXは完全なセッション永続化には劣る。
- **Follow-up**: 将来的にUX上の再認証頻度が問題になった場合は、最小限のトークン交換エッジ関数（BFF化）を別specとして検討する（Revalidation Trigger）。

### Decision: Cognito Resource Server のカスタムスコープで read/write を分離

- **Context**: Requirement 2（403判定）を実現する最小の認可モデルが必要。
- **Alternatives Considered**:
  1. `cognito:groups`（グループベース） — ユーザー管理UIの構築が前提になり、このspecのBoundaryを超える
  2. カスタムクレーム（Lambda トリガーで独自付与） — 実装コストが高く、教材の最小経路には過剰
- **Selected Approach**: `aws_cognito_resource_server` でスコープ識別子（例: `api`）を定義し、`api/items.read` / `api/items.write` の2スコープをアプリクライアントに許可する。FastAPI側は `Security(get_current_user, scopes=["api/items.write"])` のように要求スコープを宣言する。
- **Rationale**: OAuth2標準のスコープ機構であり、FastAPIの `SecurityScopes` とも自然に対応する。ロール管理UIを作らずに403判定を検証可能にできる。
- **Trade-offs**: 現時点ではユーザーにスコープを個別付与するUI/運用が無いため、実運用でのread-onlyユーザーの作成は手動（AWSコンソール/CLI）になる。認可ロジック自体は実装・テストされる。
- **Follow-up**: きめ細かいロール管理・ユーザー管理UIは Issue #40（ドメイン拡充）で検討する。

## Risks & Mitigations

- **失効した署名鍵のキャッシュ残存**（pyjwt#1051） — 教材規模では許容。将来的にキー更新頻度が上がる場合はキャッシュlifespanを短縮する。
- **リフレッシュトークンの非永続化によるUX低下**（ページリロードで再ログイン） — Requirement 4の再認証誘導で吸収。将来的にBFF化で解消可能。
- **Cognito Hosted UIのE2Eテスト困難性**（CIから実Cognitoへの依存） — タスクフェーズで、ルーティングガード自体（未認証→ログイン誘導）はモックで検証し、実Hosted UIとのフルフローはローカル/sandbox環境での手動確認に留めることを検討する。
- **items以外のドメインリソースへの認可拡張**（Issue #40） — 今回のスコープモデル（read/write）がそのまま流用できるが、リソース所有者ベースの認可は別途設計が必要になる。

## References

- [PyJWT docs](https://pyjwt.readthedocs.io/en/latest/usage.html)
- [FastAPI: OAuth2 scopes](https://fastapi.tiangolo.com/advanced/security/oauth2-scopes/)
- [FastAPI: Testing Dependencies with Overrides](https://fastapi.tiangolo.com/advanced/testing-dependencies/)
- [AWS: Verifying JSON web tokens](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-tokens-verifying-a-jwt.html)
- [Cognito PKCE docs](https://docs.aws.amazon.com/cognito/latest/developerguide/using-pkce-in-authorization-code.html)
- [authts/oidc-client-ts](https://github.com/authts/oidc-client-ts)
- [Auth0: Token Storage](https://auth0.com/docs/secure/security-guidance/data-security/token-storage)
- [Vue Router: Navigation Guards](https://router.vuejs.org/guide/advanced/navigation-guards.html)
- [aws_cognito_user_pool_client docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cognito_user_pool_client)
- [Amazon Cognito Pricing](https://aws.amazon.com/cognito/pricing/)
- [ADR-0003](../../../docs/adr/0003-keep-monorepo-through-domain-and-authn-expansion.md)
