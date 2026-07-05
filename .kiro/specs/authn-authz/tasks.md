# Implementation Plan

- [ ] 1. Foundation: 認証基盤の土台整備
- [x] 1.1 (P) Cognitoユーザープールと関連リソースを用意する
  - Cognitoユーザープール、read/writeスコープを持つResource Server、パブリッククライアント（`generate_secret = false`、Authorization Code + PKCE、Essentialsティア）、Hosted UIドメインをTerraformで宣言する
  - 既存の`*.cloudfront.net`ドメインをコールバック/ログアウトURLとして登録する
  - user pool ID・app client ID・Hosted UIドメイン・リージョンなど非機密の識別子を出力する
  - `env/*.tfvars.example`に新規変数のサンプル値を追記し、実値はコミットしない
  - 観測可能な完了状態: `terraform validate`が通り、Cognitoリソースの出力値が`terraform plan`で確認できる
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.3, 5.1, 5.2_
  - _Boundary: CognitoInfra_

- [x] 1.2 (P) APIの認証設定とJWT署名検証の基盤を用意する
  - PyJWTを依存関係に追加する
  - Cognitoのユーザープールid・リージョン・クライアントid・issuer等、認証に必要な設定値（非機密）を設定に追加する
  - JWKSエンドポイントから署名鍵を取得しキャッシュする仕組みを用意する（TTLキャッシュ、未知の鍵IDでの自動再取得を含む）
  - `.env.example`に新規設定項目のサンプル値を追記し、実値はコミットしない
  - 観測可能な完了状態: ローカルで生成したJWKSペイロードに対し、正しい鍵IDの署名鍵を取得できることをテストで確認できる
  - _Requirements: 1.1, 1.3, 5.1, 5.2_
  - _Boundary: JwksVerifier, config.py_

- [x] 1.3 (P) フロントの認証クライアント設定と型を用意する
  - `oidc-client-ts`を依存関係に追加する
  - CognitoのHosted UI・クライアントID・コールバックURL等を指すOIDCクライアント設定を用意する
  - 認証済みユーザー情報・認証ストアの状態を表す型を定義する
  - `.env.example`に新規のビルド時設定項目（`VITE_`プレフィックス、非機密）を追記する
  - 観測可能な完了状態: `vue-tsc --noEmit`が新規の型定義に対してエラー無く通る
  - _Requirements: 3.1, 3.2, 5.1, 5.2_
  - _Boundary: auth (web)_

- [x] 1.4 Cognitoトークンエンドポイントへの直接アクセスがCORS制約を受けないか確認する
  - 1.1で用意したCognitoユーザープールに対し、ブラウザからの直接アクセスを想定したクロスオリジンリクエストでトークンエンドポイントの応答ヘッダーを確認する
  - CORSが利用できない場合の代替方針（プロキシ追加等）を記録し、以降のフロント実装（2.3以降）が採用する方式を確定する
  - 観測可能な完了状態: CORS応答の有無が明文化され、フロントのトークン交換方式（直接fetchかプロキシ経由か）が決定している
  - _Requirements: 3.2_
  - _Depends: 1.1_

- [ ] 2. Core: 認証・認可ロジック本体
- [x] 2.1 未認証・無効なトークンを判定する仕組みを実装する
  - リクエストからBearerトークンを取り出し、JWKSで取得した鍵で署名を検証する
  - 有効期限切れ・発行者不一致・トークン種別不一致（アクセストークン以外）を無効と判定する
  - Cognitoのアクセストークンには`aud`クレームが無いため、`client_id`クレームをアプリのクライアントIDと比較する方式で検証する（`aud`検証は行わない）
  - 検証に失敗したリクエストは401として扱われるようにする
  - 観測可能な完了状態: 正規署名・不正署名・期限切れ・トークン種別不一致・クライアントID不一致のそれぞれについて、401判定になることをテストで確認できる
  - _Requirements: 1.1, 1.2, 1.3_
  - _Depends: 1.2_
  - _Boundary: AuthDependency_

- [x] 2.2 権限不足のリクエストを判定する仕組みを実装する
  - 検証済みリクエストが保持するスコープと、エンドポイントが要求するスコープを比較する汎用の仕組みを用意する（特定のスコープに対する特別扱いは行わない）
  - 要求スコープを満たさないリクエストは403として扱われるようにする
  - 要求スコープを満たすリクエストは通常どおり処理が進むようにする
  - 観測可能な完了状態: 要求スコープを持たないリクエストは403になり、要求スコープを持つリクエストは403にならず処理が進むことをテストで確認できる
  - _Requirements: 2.1, 2.2_
  - _Boundary: AuthDependency_

- [x] 2.3 (P) 認証状態を保持し、ログイン・ログアウト・再認証を行う仕組みを実装する
  - Cognito Hosted UIへのログイン誘導、コールバックでのコード交換、ログアウトを行う
  - 認証状態（ユーザー情報・トークン）はメモリ上にのみ保持し、ブラウザの永続ストレージには書き込まない
  - トークン失効時のサイレント再認証と、失敗時の状態破棄を行う
  - ログイン失敗時にエラー状態を保持する
  - 観測可能な完了状態: ログイン成功・ログイン失敗・ログアウト・再認証成功・再認証失敗のそれぞれで認証状態が期待通りに変化することをテストで確認できる
  - _Requirements: 3.1, 3.2, 3.4, 3.5, 4.1, 4.2_
  - _Depends: 1.3, 1.4_
  - _Boundary: AuthStore_

- [ ] 3. Integration: 既存サーフェスへの適用と横断的な配線
- [x] 3.1 (P) 既存の保護対象エンドポイントに認証・認可を適用する
  - 一覧・取得エンドポイントに認証と読み取りスコープを要求し、作成エンドポイントには認証と書き込みスコープを要求する
  - ヘルスチェックエンドポイントは引き続き認証不要のままにする
  - テストで認証状態を差し替えられるようにし、実際のCognito呼び出し無しで検証できるようにする
  - 観測可能な完了状態: 未認証での一覧・取得・作成がいずれも401になり、読み取りスコープを持たないリクエストでの一覧・取得が403になり、読み取り専用スコープでの作成が403になり、書き込みスコープでの作成が成功することをテストで確認できる
  - _Requirements: 1.4, 2.1, 2.2, 2.3_
  - _Depends: 2.2_
  - _Boundary: ItemsRouter_

- [x] 3.2 (P) ログイン画面とコールバック画面を実装する
  - ログイン画面はCognito Hosted UIへの遷移を開始する
  - コールバック画面は認証結果を受け取り、成功時は元の遷移先へ、失敗時はエラーメッセージを表示する
  - ログイン画面・コールバック画面それぞれのルートをルーティング定義に追加する
  - 観測可能な完了状態: ログイン開始操作でHosted UIへの遷移が発生し、エラー付きコールバックでエラーメッセージが画面に表示されることを確認できる
  - _Requirements: 3.1, 3.2, 3.5_
  - _Depends: 2.3_
  - _Boundary: LoginView, AuthCallbackView（ルーティング定義への追記を含むため、後続の3.4はこのタスク完了後に着手する）_

- [x] 3.3 (P) APIクライアントに認証トークンの付与と失効時の再試行を組み込む
  - 送信前に保持しているアクセストークンをリクエストに付与する
  - 401応答を受けた場合は一度だけ再認証を試み、成功時はリクエストを再試行し、失敗時はログアウト状態にしてエラーを呼び出し元に伝える
  - 既存のヘルスチェック等、認証不要な呼び出しの挙動が変わらないことを確認する
  - 観測可能な完了状態: 期限切れトークンでのリクエストが自動的に再試行され、再認証に失敗した場合はエラーが呼び出し元に伝播することをテストで確認できる
  - _Requirements: 4.1, 4.2_
  - _Depends: 2.3_
  - _Boundary: ApiClient_

- [x] 3.4 未認証ユーザーの保護画面アクセスをログインへ誘導する
  - 保護対象の画面に未認証でアクセスした際、ログイン画面へ遷移させる
  - ログイン後は元々アクセスしようとしていた画面へ戻す
  - 観測可能な完了状態: 未認証状態で保護画面のURLへ直接アクセスするとログイン画面へリダイレクトされることを確認できる
  - _Requirements: 3.1_
  - _Depends: 2.3, 3.2_
  - _Boundary: RouterGuard_

- [x] 3.5 (P) ログイン状態を画面上に表示する
  - 現在ログイン中かどうかが分かる表示を追加する
  - 観測可能な完了状態: 認証済み状態と未認証状態でそれぞれ異なる表示になることを確認できる
  - _Requirements: 3.3_
  - _Depends: 2.3_
  - _Boundary: AuthStatusBadge_

- [ ] 4. Validation: 回帰確認と実環境検証
- [x] 4.1 保護対象エンドポイントの認証・認可を横断的に検証する
  - 既存の一覧・取得・作成のテストを認証前提に更新し、未認証401・読み取りスコープ不足403（一覧・取得）・書き込みスコープ不足403（作成）・正常系の一連の経路を確認する
  - ヘルスチェックが引き続き未認証で200を返すことを回帰確認する
  - 観測可能な完了状態: 更新後のテストスイートが全て green になる
  - _Requirements: 1.1, 1.4, 2.1, 2.2, 2.3_
  - _Depends: 3.1_

- [x] 4.2 未認証時のルート保護とログアウト時の状態破棄を検証する
  - 未認証で保護画面へアクセスするとログイン画面へ誘導されることを確認する
  - ログアウト後、保護画面への再アクセスが再びブロックされることを確認する
  - 観測可能な完了状態: 両シナリオのテストが green になる
  - _Requirements: 3.1, 3.4_
  - _Depends: 3.4_

- [ ]* 4.3 Cognitoリソースと認証フローをsandbox環境で実機検証する
  - `sandbox/*`ブランチでCognito関連のTerraformリソースを実際にAWSへ適用する
  - 1.4で確定した方式（直接fetchまたはプロキシ経由）で、実際のCognito Hosted UIを用いたログイン〜APIアクセスの一連の流れを手動確認する
  - 検証後は`terraform destroy`でリソースを破棄する
  - 観測可能な完了状態: 実際のCognito Hosted UIを用いたログイン〜APIアクセスが手動確認で成功する
  - _Requirements: 3.2, 5.1_
  - _Depends: 1.1, 1.4, 3.2_

## Implementation Notes

- 1.1: `callback_urls`/`logout_urls`は`variables.tf`の新規変数にせず、`aws_cloudfront_distribution.web.domain_name`から直接導出した（design.mdのFile Structure Plan記載とCognitoInfra/Non-Goals記載が矛盾していたため、後者＝ハードコード方針を採用）。design.mdの当該記述は要フォローアップ修正。callback/logoutパスは`/callback`・`/login`固定とした — 3.2でLoginView/AuthCallbackViewのルートパスを変える場合はこのファイルも合わせて変更が必要。
- 1.2: `.env.example`はこのサンドボックスの権限設定（`.env*`へのRead deny）により編集不可。人手で以下を`services/backend/python/.env.example`に追記する必要がある:
  ```
  API_COGNITO_USER_POOL_ID=
  API_COGNITO_REGION=ap-northeast-1
  API_COGNITO_CLIENT_ID=
  API_COGNITO_ISSUER=
  ```
  同じ制約が1.3（frontend `.env.example`）にも適用される見込み。
- 1.3: frontend `.env.example`も同じ理由で編集不可。人手で以下を`services/frontend/.env.example`に追記する必要がある:
  ```
  VITE_COGNITO_USER_POOL_ID=ap-northeast-1_XXXXXXXXX
  VITE_COGNITO_REGION=ap-northeast-1
  VITE_COGNITO_CLIENT_ID=xxxxxxxxxxxxxxxxxxxxxxxxxx
  VITE_COGNITO_DOMAIN=myapp-auth
  ```
  Cognitoのログアウトは標準OIDCの`end_session_endpoint`ではなくHosted UI独自の`/logout`エンドポイント。`oidcConfig.ts`が`cognitoHostedUiDomain`を生値でexport済みなので、2.3の`logout()`はそれを使ってURLを組み立てる。`oidc-client-ts`の`userStore`既定値は`sessionStorage`（`localStorage`ではない）、`stateStore`既定値は`localStorage`（`sessionStorage`ではない）— 実際の型定義で確認済み。tokenを持つ`userStore`のみ`InMemoryWebStorage`でメモリ限定化した（`stateStore`はトークンを持たない一時的なPKCE/state値のみのため既定のまま）。
- 4.2: vue-router 5.1.0は同一fullPathへの`push()`を「冗長なナビゲーション」として`beforeEach`をスキップする（実機確認済み）。ログアウト後に同じ保護ルートへ即座に再pushするテストは素朴に書くと無意味になるため、間に`/public`への遷移を挟んで実際にガードを再実行させた。実際のログアウトは`window.location.href`によるページ全体の遷移（Cognito経由で`/login`へ）なので、この中間遷移はテスト環境の制約を回避するものであり、シナリオを弱めるものではない（レビューでmutation testing済み）。
- 1.4: 実機（sandbox）無しでの調査のため、AWS公式ドキュメント・re:Post記事に基づく判断とした（design.md「コード交換のCORS制約」参照）。Cognitoの`/oauth2/token`・`/oauth2/userInfo`はCORS対応済み、かつ本設計はパブリッククライアントのためAuthorizationヘッダを使わずpreflight起因の失敗パターンにも該当しない。直接fetch（`oidc-client-ts`既定）を採用、プロキシは追加しない。最終確認は4.3のsandbox実機検証に持ち越し。
- 2.1: `get_current_user`はスコープ判定を含まない認証専用の依存関数とした（`SecurityScopes`は使わない）。design.mdのImplementation Notes記載（`Security(get_current_user, scopes=[...])`）とRequirements Traceability表（2.3はget_current_user単独にマッピング）が矛盾していたため後者を採用 — 3.1でのルーター配線時にこの解釈を踏襲すること。
- 2.2: `require_scope(scope)`は`Depends(get_current_user)`にネストする形で実装（`scope not in user.scopes`）。レビュー1周目で「単一スコープのテストしかなく、`user.scopes != [scope]`という壊れた実装でも全テストが通ってしまう」というmutation testingでの指摘がありREJECTED → 複数スコープを持つユーザーのテストを追加し、同じmutationで新テストが落ちることを実装者・レビュアー双方で再現確認してAPPROVED。
- 3.1: GET（一覧・単体）は`Depends(require_scope("api/items.read"))`、POSTは`Depends(require_scope("api/items.write"))`をルート単位で宣言（`require_scope`が内部で`get_current_user`にネストするため1つの宣言で401+403両方をカバー）。認証テストは`conftest.py`の`authed_client`ファクトリ（`(scopes) -> AsyncClient`、未指定なら読み書き両方）で実Cognito無しに差し替え可能にした。`client`フィクスチャは無認証のまま — 未認証401テストはそちらを使う。
- 2.3: `login()`は`AuthStoreActions`の型どおり引数なし — 元の遷移先は`route.query.redirect`をstoreが直接読んでOIDCの`state`に渡し、`handleCallback()`が`user.state`を読んで`router.replace(state ?? '/')`する設計。**3.4（ルーターガード）は未認証時に必ず`/login?redirect=<元のfullPath>`へリダイレクトすること**（クエリキー名は`redirect`固定）。**3.2（LoginView）は`authStore.login()`をmount時に呼ぶだけでよく、クエリを自分で読む必要はない**。ログアウトURLはCognito独自の`/logout`エンドポイント（標準OIDCの`end_session_endpoint`ではない）— `oidcConfig.ts`の`region`をexport済み。レビューで`state`のオープンリダイレクト可能性を実機検証済み（vue-routerの`replace()`は文字列を常にpathとして解決するため`/https://evil.example`のような未マッチルートになるだけで、実ブラウザのHistory APIもクロスオリジンを拒否 — 脆弱性ではない）。
