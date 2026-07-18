#!/usr/bin/env bash
# devcontainer の initializeCommand 本体。コンテナビルド前にホスト側で実行される（冪等）。
#
# 背景（#546）: Codespaces の `devcontainer up` はデフォルトの buildx "docker" ドライバで
# ビルドするが、`type=registry`（:buildcache）はこのドライバでは読み込めず、inline cache
# （:latest）も host 側 Docker Engine の containerd snapshotter 設定次第で効かないことがある。
# ビルド前に docker-container ドライバの builder へ切り替えておけば、host 側の設定に関係なく
# 両方のキャッシュが機能する。
# initializeCommand が非ゼロ終了すると devcontainer up 全体（Codespace 作成）が失敗するため、
# ここでは何が起きても最終的に exit 0 にする。失敗時はデフォルトの docker ドライバのまま
# フォールバックするだけで、現状（キャッシュが効かない）と同じ挙動に留まる。
#
# docker buildx use はリポジトリ単位ではなくホスト全体のグローバル設定を書き換えるため、
# ローカルの VS Code Dev Containers 拡張等（Codespaces 以外）では実行しない。Codespaces は
# コンテナ内に CODESPACES=true を自動設定しており、initializeCommand はその devcontainer up
# プロセスの子として動くため同じ環境変数を継承している。
if [ "${CODESPACES:-}" != "true" ]; then
  echo "INFO: Codespaces 環境ではないため、buildx ドライバの切り替えをスキップします" >&2
  exit 0
fi

BUILDER_NAME="devcon-builder"

if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
  if ! docker buildx create --name "$BUILDER_NAME" --driver docker-container --bootstrap; then
    echo "WARN: docker-container ドライバの builder 作成に失敗。docker ドライバのままフォールバックします" >&2
    exit 0
  fi
fi

if ! docker buildx use "$BUILDER_NAME"; then
  echo "WARN: buildx builder の切り替えに失敗。docker ドライバのままフォールバックします" >&2
fi

exit 0
