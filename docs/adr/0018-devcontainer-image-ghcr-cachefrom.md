# ADR-0018: devcontainer イメージは GHCR に事前ビルド公開し、`build.cacheFrom` で取り込む

- **Status:** Accepted
- **Date:** 2026-07-17
- **Deciders:** itouhi
- **Related:** #532、devcontainer-image-prebuild-proposal.md、
  [ADR-0011](0011-scaffold-template-in-place.md)・[ADR-0012](0012-reusable-workflow-in-repo-tag-versioned.md)
  （同じ「本リポジトリ自身が配布物」という設計方針の延長）

## Context

`.devcontainer/devcontainer.json` は `build.dockerfile` のみを指定しており、Codespaces /
ローカル Dev Containers 拡張のどちらも初回起動のたびに `.devcontainer/Dockerfile` を
ゼロからビルドする（Terraform・tflint・trivy・checkov・AWS CLI・Node.js・copier 等のインストール
がフルで走る）。初回起動を、ビルド済みイメージの取得によって速くしたい。

本リポジトリは copier テンプレートのソースでもあり（ADR-0010/0011）、`iwata-jawsug-jp/devcon`
（開発用・private）と `iwata-jawsug-jp/devcon`（公開ミラー）の2リポジトリ運用（`docs/release.md`）
の上に成り立つ。この決定は両方の文脈で破綻しない設計でなければならない。

検討した論点は3つ（詳細は devcontainer-image-prebuild-proposal.md 参照）。

### 論点1: レジストリの選定

GHCR（GitHub Container Registry）/ Docker Hub / AWS ECR を比較。GHCR は CI からの push が
Actions の `GITHUB_TOKEN` のみで完結し新規シークレットが不要、Codespaces は同一リポジトリ紐づき
パッケージに自動認証する。Docker Hub は別アカウント管理が増え匿名 pull のレート制限もある。
AWS ECR は「devcontainer を開くために先に AWS 認証が要る」循環が生まれ、fork した人が AWS を
一切セットアップしていない段階で devcontainer を開けなくなるため不適合。

### 論点2: `devcontainer.json` 側の方式

`"image"` への完全移行（最速だが、`Dockerfile` を編集してもローカル **Rebuild Container** に
反映されない。かつ、copier 生成直後でまだ一度も自分のリポジトリで CI を回していない
プロジェクトでは参照先イメージが存在せず devcontainer 自体が開けなくなるハードエラーになる）か、
`"build" + "cacheFrom"`（ローカル `docker build` は維持しつつ GHCR の公開済みレイヤーをキャッシュ
として取り込む）かを比較。後者は実機検証で、キャッシュ元イメージが存在しない場合も
`docker build` 自体は失敗せず通常ビルドにフォールバックする（soft-fail）ことを確認済み。

### 論点3: どのリポジトリが GHCR に publish するか

事前ビルドイメージをどちらのリポジトリ名前空間で公開するかの判断。`iwata-jawsug-jp/devcon`
自身の名前空間に publish する案もあったが、公開して広く再利用させる対象は
`iwata-jawsug-jp/devcon`（公開ミラー）であるべきと判断（ユーザー決定）。
`tools/script/publish-to-public.sh` が既に持つ `iwata-jawsug-jp/devcon` → `iwata-jawsug-jp/devcon`
の文字列変換（GitHub Release 公開時、`docs/release.md` 参照）にそのまま乗せられるため、
新しい変換ロジックを追加する必要がない。

## Decision

1. **レジストリは GHCR。**
2. **`devcontainer.json` は `build.dockerfile` を維持し、`build.cacheFrom` に
   `ghcr.io/iwata-jawsug-jp/devcon/devcontainer:buildcache` を直接（ハードコードで）指定する
   （タグの理由は 7. 参照）。** `iwata-jawsug-jp/devcon`・公開ミラー・copier 生成先のすべてが、
   この1つの canonical なイメージをキャッシュ元として共有参照する（下記「訂正」参照）。
3. **公開ワークフロー（`.github/workflows/devcontainer-build.yml`）は `iwata-jawsug-jp/devcon`
   でのみ実行するようジョブレベルの `if: github.repository == 'iwata-jawsug-jp/devcon'` で
   ガードする。** push 先タグも同じ canonical なイメージ1箇所（
   `ghcr.io/iwata-jawsug-jp/devcon/devcontainer`）に固定する。`iwata-jawsug-jp/devcon` 自身は
   push しない（他組織の GHCR への書き込み権限が無く、そもそも実行してはいけない）。
   ワークフローの起動自体は `GitHub Release 公開 → publish.yml → 公開ミラーの main 更新 →
devcontainer-build.yml の push トリガー` の連鎖で起きる。

> **訂正1（2026-07-17, #538）:** 初版では 2./3. の参照先を `ghcr.io/iwata-jawsug-jp/devcon/devcontainer`
> と書き、`tools/script/publish-to-public.sh` の文字列変換（`iwata-jawsug-jp/devcon` →
> `iwata-jawsug-jp/devcon`）で公開ミラー向けに自動的に書き換わる設計にしていた。この設計だと
> **`iwata-jawsug-jp/devcon` 自身が参照する `cacheFrom` は永久に publish されない自分専用の
> 名前空間を指したままになり、`devcon` 自身は何度 Rebuild Container してもキャッシュの
> 恩恵を一切受けられない**（常に soft-fail で通常ビルドにフォールバックするだけ）という欠陥が
> あった。実機で GHCR パッケージの公開可視性を確認した際に発覚。`iwata-jawsug-jp/devcon` も
> 公開ミラーの canonical なイメージを直接参照する形（上記の通り）に修正し、
> publish 時の文字列変換に依存しない設計に改めた。

4. **`devcontainer-build.yml` は `copier.yml` の `_exclude` に含める。** `publish.yml` と同じく
   `iwata-jawsug-jp/devcon` ⇄ `iwata-jawsug-jp/devcon` のリポジトリペア専用の配管であり、
   copier 生成先には「常にスキップされるだけの死んだジョブ」として残ってしまうため。
   generated project は独自の GHCR 名前空間を持たず、公開ミラーの正規イメージを
   `cacheFrom` で共有参照する。
5. **マルチアーキ対応（arm64）は現時点で行わない。** amd64 のみを publish する。
6. **`copier.yml` の `github_org`/`github_repo` バリデータへの小文字強制は追加しない。**
   generated project は GHCR パスを `github_org`/`github_repo` から動的に組み立てないため
   （4. の設計）、大文字小文字はこの用途に影響しない。
7. **`cache-from`/`cache-to` は `tags` とは別タグ（`:buildcache`）にする。**

> **訂正2（2026-07-17, #538）:** 初版では `cache-to`/`cache-from` も `tags` と同じ `:latest`
> タグを共有していた。`cache-to`（`mode=max`）が書き込む buildkit cache config manifest が
> 実イメージを上書きしてしまい、`:latest` が「`docker run` できない、キャッシュメタデータのみの
> 参照」になっていることを実機（`docker buildx imagetools inspect --raw`）で確認した。この
> 状態で `docker build --cache-from` を実行すると、レイヤーの一部は取得できるものの最終的な
> イメージ export に失敗しビルド自体が壊れることも実機確認した。`cache-from`/`cache-to` を
> `:buildcache` という別タグに分離し、`devcontainer.json` の `cacheFrom` もそちらを参照する
> よう修正した。

> **訂正3（2026-07-17, #542）:** 「良い面」「トレードオフ」に記載した #538 の実機検証（全12
> `RUN` ステップが `CACHED`）は、`.devcontainer/Dockerfile` に対して `docker build
--cache-from` を**直接**実行するテストであり、Codespaces / VS Code Dev Containers / copier
> 生成先が実際に使う経路（devcontainers CLI 経由のビルド）を通していなかった。実際に
> Codespaces でビルドしたところ、`RUN` が1件も `CACHED` にならず全ステップが実行された
> （#542）。devcontainers CLI は `devcontainer.json` の `features`（本リポジトリでは
> `docker-in-docker`）を組み込む際、生の `Dockerfile` をそのままビルドせず、ベースステージへ
> `AS dev_container_auto_added_stage_label` を付与し `_DEV_CONTAINERS_BASE_IMAGE` 等の
> build-arg と追加ビルドコンテキスト（`dev_containers_feature_content_source`）を注入した
> **別のビルドグラフ**を組み立てる。`devcontainer-build.yml` は `docker/build-push-action` で
> 生の `Dockerfile` を直接ビルドしており devcontainers CLI を経由しないため、`:buildcache` は
> devcontainers CLI が実際に組み立てるグラフとは op ダイジェストのチェーンが異なり、
> `FROM` 起点で一致判定する BuildKit のレジストリキャッシュが一切マッチしない。GHCR パッケージ
> の可視性・認証は問題なく（`[auth]` トークン取得・`importing cache manifest` はいずれも
> 成功）、これはアクセス権の問題ではなく**キャッシュを生成するビルド経路と実際に消費するビルド
> 経路が構造的に異なる**という設計不備だった。`devcontainer-build.yml` 自身の直近実行
> （v0.5.1、`iwata-jawsug-jp/devcon` の run 29618796597）のログでも `CACHED` が0件であることを
> `gh run view --log` で確認済み（自分の直前ビルドが書いたはずの `:buildcache` すら再利用でき
> ていない）。修正: `devcontainer-build.yml` を `docker/build-push-action` から
> `@devcontainers/cli` の `devcontainer build` コマンド経由のビルドに変更した（#542）。
> `--cache-from`/`--cache-to` はそのまま buildx へ伝播するため（CLI ソース
> `devContainersSpecCLI.js` で確認）、生成される `:buildcache` は devcontainers CLI が
> 実際に組み立てるグラフ（features 込み）と一致するようになる。ローカルで
> `devcontainer build --cache-from ghcr.io/iwata-jawsug-jp/devcon/devcontainer:buildcache`
> を実行し、既存の `:buildcache`（devcontainers CLI 経由の修正前は一度もこの経路で書かれた
> ことがないにも関わらず）に対して `.devcontainer/Dockerfile` 由来の全 RUN ステップが
> `CACHED` になることを実機確認済み（features 側の追加インストールステージ自体は
> devcontainers CLI 経由でビルドされたことが一度も無かったため今回は未キャッシュで実行され
> たが、これは今回の修正で `:buildcache` に書き込まれるため次回以降はキャッシュされる）。

## Consequences

- 良い面: `Dockerfile` が前回公開時点と同じであれば、初回起動がほぼ pull のみの速度になる
  （訂正3参照: `devcontainer-build.yml` を devcontainers CLI 経由のビルドに修正し、実際の
  Codespaces 消費経路と同じグラフでキャッシュヒットすることをローカルで実機確認済み、#542）。
  copier 生成直後（まだ CI を一度も回していない）プロジェクトでも soft-fail により壊れない。
  `Dockerfile` 編集 → ローカル即 Rebuild Container という既存の開発者体験を維持する。
- トレードオフ: `devcon` 自身のローカル/Codespaces 利用でも、キャッシュ元は公開ミラー側の
  イメージになる（自分専用の事前ビルドは持たない）。公開ミラー側の初回 push（GitHub Release）
  までは、`devcon` でも公開ミラーでも通常ビルドと同じ速度のまま（regression ではないが
  恩恵もまだ無い）。GHCR パッケージ自体の公開可視性、および実際のキャッシュヒットによる
  高速化は v0.5.1 で実機確認済み（2026-07-17）: `docker manifest inspect` による匿名 pull
  確認、`docker buildx imagetools inspect --raw` で `:latest`（実イメージ・OCI image index）
  と `:buildcache`（cache config manifest）が正しく分離されていることの確認、実際に
  `docker build --cache-from ghcr.io/iwata-jawsug-jp/devcon/devcontainer:buildcache` を
  実行し `.devcontainer/Dockerfile` の全12個の `RUN` ステップ（Python/GitHub CLI/Claude Code/
  conftest/tflint/Node.js/AWS CLI/Terraform/Trivy/Checkov/uv/copier のインストール）すべてが
  `CACHED` と表示されビルド時間 1分21秒で成功したことを確認（#538）。**ただしこれは
  devcontainers CLI を経由しない直接ビルドでの確認であり、実際の Codespaces 利用時には
  キャッシュヒットしない不具合が後に発覚し、#542 で修正済み（訂正3参照）。**
- 運用負担: GHCR は新規パッケージを初回 push 時に private 作成することがあるため、初回
  ワークフロー実行後に `iwata-jawsug-jp` 組織の管理者が Package settings で可視性を Public に
  変更する一回限りの手作業が必要（自動化できない）。
- 見直しのトリガー: 将来 arm64（Apple Silicon）ローカル利用が増え、キャッシュ非該当による
  ビルド遅延が問題になった場合、マルチアーキ publish（`docker/build-push-action` の
  `platforms`）の追加を再検討する。
