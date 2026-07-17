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
   `ghcr.io/iwata-jawsug-jp/devcon/devcontainer:latest` を追加する。** ソース（開発用リポジトリ）
   側はこの文字列のまま書く。`tools/script/publish-to-public.sh` の既存変換により、公開ミラーでは
   自動的に `ghcr.io/iwata-jawsug-jp/devcon/devcontainer:latest` になる。
3. **公開ワークフロー（`.github/workflows/devcontainer-build.yml`）は `iwata-jawsug-jp/devcon`
   でのみ実行するようジョブレベルの `if: github.repository == 'iwata-jawsug-jp/devcon'` で
   ガードする。** `iwata-jawsug-jp/devcon` 自身は push しない（誤って自分の名前空間に publish
   しないため、かつ二重ビルドを避けるため）。ワークフローの起動自体は
   `GitHub Release 公開 → publish.yml → 公開ミラーの main 更新 → devcontainer-build.yml の
push トリガー` の連鎖で起きる。
4. **`devcontainer-build.yml` は `copier.yml` の `_exclude` に含める。** `publish.yml` と同じく
   `iwata-jawsug-jp/devcon` ⇄ `iwata-jawsug-jp/devcon` のリポジトリペア専用の配管であり、
   copier 生成先には「常にスキップされるだけの死んだジョブ」として残ってしまうため。
   generated project は独自の GHCR 名前空間を持たず、公開ミラーの正規イメージを
   `cacheFrom` で共有参照する。
5. **マルチアーキ対応（arm64）は現時点で行わない。** amd64 のみを publish する。
6. **`copier.yml` の `github_org`/`github_repo` バリデータへの小文字強制は追加しない。**
   generated project は GHCR パスを `github_org`/`github_repo` から動的に組み立てないため
   （4. の設計）、大文字小文字はこの用途に影響しない。

## Consequences

- 良い面: `Dockerfile` が前回公開時点と同じであれば、初回起動がほぼ pull のみの速度になる。
  copier 生成直後（まだ CI を一度も回していない）プロジェクトでも soft-fail により壊れない。
  `Dockerfile` 編集 → ローカル即 Rebuild Container という既存の開発者体験を維持する。
- トレードオフ: `devcon` 自身のローカル/Codespaces 利用でも、キャッシュ元は公開ミラー側の
  イメージになる（自分専用の事前ビルドは持たない）。公開ミラー側の初回 push（GitHub Release）
  までは、`devcon` でも公開ミラーでも通常ビルドと同じ速度のまま（regression ではないが
  恩恵もまだ無い）。
- 運用負担: GHCR は新規パッケージを初回 push 時に private 作成することがあるため、初回
  ワークフロー実行後に `iwata-jawsug-jp` 組織の管理者が Package settings で可視性を Public に
  変更する一回限りの手作業が必要（自動化できない）。
- 見直しのトリガー: 将来 arm64（Apple Silicon）ローカル利用が増え、キャッシュ非該当による
  ビルド遅延が問題になった場合、マルチアーキ publish（`docker/build-push-action` の
  `platforms`）の追加を再検討する。
