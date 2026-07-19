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
   （タグの理由は 7. 参照。訂正4で `:latest` も加えた配列に変更したが、訂正6で
   `:buildcache` 単体に戻した）。** `iwata-jawsug-jp/devcon`・
   公開ミラー・copier 生成先のすべてが、この1つの canonical なイメージをキャッシュ元として
   共有参照する（下記「訂正」参照）。
3. **公開ワークフロー（`.github/workflows/devcontainer-build.yml`）は `iwata-jawsug-jp/devcon`
   でのみ実行するようジョブレベルの `if: github.repository == 'iwata-jawsug-jp/devcon'` で
   ガードする。** push 先タグも同じ canonical なイメージ1箇所（
   `ghcr.io/iwata-jawsug-jp/devcon/devcontainer`）に固定する。`iwata-jawsug-jp/devcon` 自身は
   push しない（他組織の GHCR への書き込み権限が無く、そもそも実行してはいけない）。
   ワークフローの起動自体は `GitHub Release 公開 → publish.yml → 公開ミラーの main 更新 →
devcontainer-build.yml の push トリガー` の連鎖で起きる。
4. **`devcontainer.json` に `initializeCommand": "bash .devcontainer/initialize.sh"` を追加し、
   Codespaces（`CODESPACES=true`）でのみコンテナビルド前にホスト側で buildx builder を
   `docker-container` ドライバへ切り替える（訂正5参照）。** 失敗時は必ず `exit 0` で抜け
   デフォルトの `docker` ドライバへフォールバックする（soft-fail、Codespace 作成自体は
   壊さない）。ローカルの VS Code Dev Containers 拡張では `docker buildx use` がホスト全体の
   グローバル設定を書き換えてしまう副作用を避けるため何もしない。

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

> **訂正4（2026-07-18, #546）:** 訂正3の修正を v0.5.2 としてリリースし公開ミラーの
> `devcontainer-build.yml` が実際に green（全 `RUN` が `CACHED`、実機確認済み）になった後も、
> **実際の Codespaces で Rebuild Container すると依然として `RUN` が1件も `CACHED` にならない**
> ことが実機で判明した。ビルドグラフの不一致（訂正3）は解消済みだったが、別レイヤーの原因が
> あった: Codespaces の `devcontainer up` はビルドログに `"default" instance using docker
driver` と出る通り、デフォルトの `docker` buildx ドライバを使う。一方、
> `devcontainer-build.yml`（CI）や訂正3の実機検証はいずれも `docker/setup-buildx-action@v4` で
> 明示的に `driver: docker-container` を設定していた。**`type=registry` 形式のレジストリ
> キャッシュ（`cache-from`/`cache-to` に指定していた `:buildcache`）は `docker-container`
> ドライバでしか使えず、`docker` ドライバでは読み込めない**（Docker 公式ドキュメント
> [Cache storage backends](https://docs.docker.com/build/cache/backends/)、
> [docker/buildx#2165](https://github.com/docker/buildx/discussions/2165) で確認）。
> `importing cache manifest` 自体はエラーなく完了する（メタデータの取得は driver を問わず
> できる）ため一見正常に見えるが、実際のキャッシュ適用は一切行われない。Codespaces の
> ビルド環境（デフォルトビルダー）はリポジトリ側から `docker-container` に強制する手段が
> 無いため、`type=registry` キャッシュに依存する設計は Codespaces では原理的に機能しない。
>
> 実機で `docker buildx use default`（`docker` ドライバに切り替え、Codespaces と同条件）にして
> 再現したのち、`cacheFrom` を `:buildcache`（`type=registry`）ではなく `:latest`（実イメージ）
> に変えて実行したところ、`docker` ドライバでも全 `RUN` ステップが `CACHED` になることを確認
> した。devcontainers CLI は `docker buildx build` 実行時に `--build-arg
BUILDKIT_INLINE_CACHE=1` を常に自動付与するため、`:latest` には push 時点で
> [inline cache](https://docs.docker.com/build/cache/backends/inline/) が既に埋め込まれており、
> `type=registry` を使わない素の `--cache-from <image>`（inline cache 読み込み）は `docker`
> ドライバでも動作する。`devcontainer.json` の `build.cacheFrom` を `:buildcache` 単体から
> `["ghcr.io/.../devcontainer:latest", "ghcr.io/.../devcontainer:buildcache"]` の配列に変更し
> （`:latest` で `docker` ドライバのデフォルト環境をカバーしつつ、`:buildcache` は
> `docker-container` ドライバを使う開発者向けに残す）、devcontainer.json 自体の設定のまま
> `docker` ドライバで全19件 `CACHED`・約19.5秒で成功することを実機確認済み（#546）。
> `devcontainer-build.yml`（CI）側の変更は不要（`:latest` push 時に inline cache が既に
> 付与されているため）。

> **訂正5（2026-07-18, #546）:** 訂正4（`cacheFrom` への `:latest` 追加）をマージ後、実際に
> 新規作成した Codespaces で再確認したところ、`RUN` は依然として1件もキャッシュヒットしなかった。
> 現在稼働中のこの Codespaces 自身の作成ログ（`/workspaces/.codespaces/.persistedshare/creation.log`）
> でも同じ症状を再実機確認した（`importing cache manifest` は `:buildcache`・`:latest` 両方とも
> 成功するが、`RUN` 2/14〜11/14 は全て実行される）。
>
> ホスト側 Docker Engine の containerd snapshotter 有効/無効を直接確認する手段はやはり無かった
> （`docker info` は `docker-in-docker` feature が作る入れ子の dockerd を見るだけで、Codespaces
> がビルドに使うホスト側 Docker Engine とは別物であることを実機確認済み）。ただし creation.log
> 冒頭が参照する `github/codespaces-host-images` の README で、ホストの `moby-engine` が
> **24.0.x 系**であることが判明した。containerd image store（containerd snapshotter）は
> Moby/Docker Engine では `daemon.json` に `features.containerd-snapshotter: true` を明示しない
> 限り有効にならないオプトイン機能であり、Codespaces のホストイメージがこれを有効化している
> という情報はどこにも無い。デフォルト無効という前提のほうが、`type=registry` に加え `:latest`
> の inline cache も `docker` ドライバでは効かないという実機症状と整合する。
>
> `docker-container` ドライバは自前の buildkitd コンテナで完結し、ホスト側の containerd
> snapshotter 設定に依存しない（[Cache storage backends](https://docs.docker.com/build/cache/backends/)）。
> devcontainer spec の `initializeCommand` はコンテナビルド前にホスト側で実行されるフックである
> ため、ここで `docker buildx create --driver docker-container --use` を実行し、Codespaces
> 自身が呼ぶ `devcontainer up` のビルドが `docker-container` ドライバを使うよう仕向けられないか
> 実機検証した（`devcontainer build` コマンドは `initializeCommand` を一切実行しないため代替に
> ならないことも確認済み。Codespaces が実際に使うのは `devcontainer up`）。
>
> 最小構成の devcontainer で検証したところ、`initializeCommand` から builder を切り替えると
> ビルドログの `building with` 行が `"default" instance using docker driver` から
> `"devcon-builder" instance using docker-container driver` に変わることを実機確認した。
> また `initializeCommand` が非ゼロ終了すると `devcontainer up` 全体（Codespace 作成そのもの）
> が失敗することも実機確認したため、`.devcontainer/initialize.sh` は builder の作成・切り替え
> のどちらが失敗しても必ず `exit 0` で抜け、デフォルトの `docker` ドライバのままフォールバック
> する設計にした（最悪でも現状と同じ「キャッシュなしの通常ビルド」に留まり、Codespace 作成自体
> は壊さない）。
>
> 実際の `devcon` の `.devcontainer`（本物の `Dockerfile` と `cacheFrom` 設定そのまま）を
> 隔離ディレクトリにコピーし `devcontainer up --skip-post-create` を実行したところ、
> `docker-container` ドライバに切り替わった上で `RUN` 2/14〜14/14 の13件すべてが `CACHED`、
> `outcome: success` でコンテナ作成まで成功することを実機確認した。ただしこの検証は本セッション
> の入れ子 dockerd（containerd snapshotter 有効）上で行ったものであり、containerd snapshotter
> が無効なホスト環境そのものは再現できていなかった。`devcontainer.json` に
> `"initializeCommand": "bash .devcontainer/initialize.sh"` を追加した。
>
> **その後、PR #548 のブランチから実際に Codespaces を新規作成（Rebuild Container 相当）して
> 最終確認した。** `initializeCommand` が `devcon-builder`（`docker-container` ドライバ）
> を作成・使用し、本体のビルドが `building with "devcon-builder" instance using
docker-container driver` になった上で、`Dockerfile` 由来の `RUN` 13件（2/14〜14/14。apt
> 基本パッケージ・Python 3.14・Node.js・AWS CLI・Terraform・tflint・trivy・checkov・conftest・
> gh・claude-code・uv・copier）が**すべて `CACHED`** になることを実機確認した。containerd
> snapshotter が実際に無効なホスト（moby-engine 24.0.x 系）であっても `docker-container`
> ドライバ経由なら registry cache（`:buildcache`）・inline cache（`:latest`）のどちらも問題なく
> 機能することが確定した。
>
> なお `docker-in-docker` feature 自体のインストールステージ（`dev_containers_target_stage 4/4`、
> `--mount=type=bind,from=dev_containers_feature_content_source` で feature コンテンツを
> bind mount する RUN）だけは今回も毎回 `CACHED` にならず実行される（訂正3で触れた通り、feature
> コンテンツの一時ディレクトリはビルドごとに生成され直すため、この1ステップは devcontainers CLI
> の feature 機構そのものの制約で恒常的にキャッシュ対象外になる）。所要47.8秒程度で
> `Dockerfile` 側の重い install 群（今回の本題）とは無関係な既知の残差であり、追加対応はしない。
>
> `docker buildx use` はリポジトリ単位ではなくホスト全体のグローバル設定を書き換えるため、
> ローカルの VS Code Dev Containers 拡張（Codespaces 以外）で同じ `devcontainer.json` を使うと
> 開発者の buildx デフォルト builder を他プロジェクトの分まで勝手に切り替えてしまう副作用が
> ある。Codespaces はコンテナ内に `CODESPACES=true` を自動設定しており、`initializeCommand` は
> その `devcontainer up` プロセスの子として動くため同じ環境変数を継承している。
> `.devcontainer/initialize.sh` の先頭で `CODESPACES=true` を確認し、Codespaces 以外では
> switch 処理そのものをスキップして `docker` ドライバのまま何もしないようにした。最小構成の
> devcontainer で `CODESPACES=false`／`CODESPACES=true` 双方を実機確認済み（前者は
> `building with "default" instance using docker driver` のまま、後者のみ builder が
> 切り替わる）。

> **訂正6（2026-07-18, #552）:** 訂正5で `docker-container` ドライバへの切り替えが本体の
> ビルドで機能することを確認した際、`:buildcache`（registry cache）・`:latest`（inline
> cache）のどちらも問題なく機能すると確認していた（訂正5末尾）。`:latest` はそもそも訂正4で
> `docker` ドライバ（Codespaces のデフォルト）に registry cache が読めない問題への回避策として
> 追加したものであり、訂正5でドライバ自体を `docker-container` に切り替えられるようになった今は
> 不要ではないかという疑問から、`cacheFrom` を `:buildcache` 単体に戻して切り分けた。実際に
> このブランチから新規 Codespaces を作成したところ、`building with "devcon-builder"
instance using docker-container driver` の下で `Dockerfile` 由来の `RUN` 14件全てが
> `CACHED` になることを実機確認した（`docker-in-docker` feature インストールステージのみ
> 訂正3・訂正5と同じ既知の制約で毎回未キャッシュ）。`:latest` 有り（訂正4）と同等のキャッシュ
> ヒット率を `:buildcache` 単体で達成できることが確定したため、`cacheFrom` を `:buildcache`
> 単体に戻した（#552）。`:latest` の push・inline cache 埋め込み自体は 7. の理由で
> `devcontainer-build.yml` 側は引き続き行う（`docker` ドライバへのフォールバック時の保険として
> 残す）。

## Consequences

- 良い面: `Dockerfile` が前回公開時点と同じであれば、初回起動がほぼ pull のみの速度になる
  （訂正3・訂正4参照: `devcontainer-build.yml` を devcontainers CLI 経由のビルドに修正した
  だけでは不十分で、Codespaces が使う `docker` buildx ドライバは `type=registry` キャッシュを
  読めないため、`cacheFrom` に inline cache 対応の `:latest` を追加してようやく `docker`
  ドライバでも `CACHED` になることを実機確認済み、#542・#546）。それでも実際の Codespaces では
  ホスト側 Docker Engine の containerd snapshotter が無効と見られ `:latest` の inline cache も
  効かなかったため、訂正5で `initializeCommand` からビルド前に `docker-container` ドライバへ
  切り替える仕組みを追加し、実際に Codespaces を新規作成して最終確認した結果、`Dockerfile` 由来の
  `RUN` 13件全てが `CACHED` になることを実機確認済み（#546）。
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
