#!/usr/bin/env bash
# devcontainer の postCreateCommand 本体。rebuild のたびに実行される（冪等）。
#  1) 永続ボリュームの整備（init-persist.sh）
#  2) 各ツールのバージョン表示（起動検証 — ここが失敗したらイメージが壊れているので fail させる）
#  3) make setup（依存導入 + pre-commit フック）
set -euo pipefail

# postCreateCommand は workspaceFolder で実行されるが、どこから呼ばれても
# リポジトリルートで動くようスクリプト位置から解決する
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# 1) マウントした永続ボリュームの所有権・bash 履歴を整える（冪等）
bash .devcontainer/init-persist.sh

# 2) 起動検証: 主要ツールのバージョンを表示（欠けていれば set -e で fail）
terraform -version
tflint --version
trivy --version
checkov --version
aws --version
node --version
python3 --version
uv --version
rg --version | head -1
gh --version | head -1
docker --version

# 3) 依存導入 + pre-commit フック（uv sync / npm install / pre-commit install — いずれも冪等）。
# ネットワーク断などで失敗してもコンテナ起動自体は成立させたいので、ここだけは
# 非ゼロ終了でコンテナ作成を失敗扱いにせず WARN を出して手動リトライへ誘導する
# （postCreateCommand の失敗は VS Code 上で「作成エラー」となり開発に入れなくなるため）。
make setup || echo "WARN: make setup failed — run 'make setup' manually (deps + pre-commit hooks are not installed yet)"
