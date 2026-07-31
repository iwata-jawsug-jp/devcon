#!/usr/bin/env bash
# 開発用ツリー・公開用ツリー・その2つを起点に copier 生成した2つの生成先ツリー、計4本に対して
# check-tree-health.sh を通しで実行する。#699（ADR-0028 実装フェーズ①）。
#
# 「検証している経路（開発用ツリー起点の生成）と、実際に使われる経路（公開用ツリー起点の生成）が
# 食い違っている」という課題（提案書 §2.1・ADR-0028 Context）に対応するため、生成は必ず両方の
# 起点から行う。生成先どうしの差分（課題D: 起点により成果物が変わる問題）も検出する。
#
# Usage: verify-tree-health.sh [--strict]
#   --strict を渡すと、いずれかのチェックで問題が見つかった時点で exit 1 になる。
#   Epic #698（④⑤⑥の完了によりリンク切れ・差分が実測0になったこと）を受けて、
#   `make tree-health`・CI（reusable-tree-health.yml）とも既定で --strict を渡す
#   （blocking 化）。フラグ自体は探索的なローカル調査用に残す。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO_ROOT/tools/script/check-tree-health.sh"

STRICT_FLAG=()
if [[ "${1:-}" == "--strict" ]]; then
  STRICT_FLAG=(--strict)
fi

# copier copy はローカルパスを直接ソースにする場合、git ではなく作業ツリーのファイルシステムを
# そのまま読む（--vcs-ref=HEAD を指定していても）。そのため、コミットされていない変更や
# git-ignore/exclude 対象のファイルまで生成物に混入し得る（DirtyLocalWarning）。
# CI は actions/checkout 直後のクリーンな状態で実行するため影響しないが、ローカルで
# `make tree-health` を未コミット変更がある状態で実行すると、「開発用ツリー起点」の結果が
# 実行のたびに変わり得る。publish-to-public.sh 側は `git archive HEAD` を使うため
# コミット済みの内容しか見ない（この非対称性のため、生成先どうしの差分にも未コミット分の
# ファイルが混ざり得る）。再現性のために、ローカル実行時は一言警告するだけに留める
# （CI 用途を妨げないよう exit はしない）。
if [[ -n "$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null)" ]]; then
  echo "[verify-tree-health] 警告: 開発用ツリーに未コミットの変更があります。" >&2
  echo "  copier は作業ツリーをそのまま生成元にするため、生成先（開発用ツリー起点）の" >&2
  echo "  結果に未コミットの変更が混入します（公開用ツリー起点は git archive HEAD のため無関係）。" >&2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TEST_PROJECT_NAME="${TEST_PROJECT_NAME:-tree-health-verify}"
TEST_GITHUB_ORG="${TEST_GITHUB_ORG:-example-org}"
TEST_AWS_REGION="${TEST_AWS_REGION:-us-east-1}"

PUBLIC_TREE="$WORK/public"
GEN_FROM_DEV="$WORK/gen-from-dev"
GEN_FROM_PUBLIC="$WORK/gen-from-public"

echo "[verify-tree-health] 開発用ツリーのリンクチェック ..."
overall_status=0
"$CHECK" "$REPO_ROOT" --label "dev" "${STRICT_FLAG[@]}" || overall_status=$?

echo "[verify-tree-health] publish-to-public.sh --dry-run で公開用ツリーを構築 ..."
DRY_RUN=1 DRY_RUN_OUT="$PUBLIC_TREE" "$REPO_ROOT/tools/script/publish-to-public.sh" HEAD >/dev/null

echo "[verify-tree-health] 公開用ツリーのリンクチェック ..."
"$CHECK" "$PUBLIC_TREE" --label "public" "${STRICT_FLAG[@]}" || overall_status=$?

# copier copy に --vcs-ref=HEAD を渡すには生成元が git リポジトリである必要がある。
# publish-to-public.sh の dry-run 出力はプレーンなファイルコピーなので、ここで最小限の
# git リポジトリ化を行う（verify-scaffold.sh が copier update の往復チェックで行っているのと
# 同じ考え方: 検証専用の使い捨てコミット）。
(
  cd "$PUBLIC_TREE"
  git init -q
  git -c user.email=tree-health@example.invalid -c user.name=tree-health add -A
  git -c user.email=tree-health@example.invalid -c user.name=tree-health commit -q -m "tree-health: public snapshot"
)

echo "[verify-tree-health] 開発用ツリー起点で copier 生成 ..."
copier copy \
  --vcs-ref=HEAD \
  --data "project_name=$TEST_PROJECT_NAME" \
  --data "github_org=$TEST_GITHUB_ORG" \
  --data "github_repo=$TEST_PROJECT_NAME" \
  --data "aws_region=$TEST_AWS_REGION" \
  --defaults --trust \
  "$REPO_ROOT" "$GEN_FROM_DEV" >/dev/null

echo "[verify-tree-health] 公開用ツリー起点で copier 生成 ..."
copier copy \
  --vcs-ref=HEAD \
  --data "project_name=$TEST_PROJECT_NAME" \
  --data "github_org=$TEST_GITHUB_ORG" \
  --data "github_repo=$TEST_PROJECT_NAME" \
  --data "aws_region=$TEST_AWS_REGION" \
  --defaults --trust \
  "$PUBLIC_TREE" "$GEN_FROM_PUBLIC" >/dev/null

echo "[verify-tree-health] 生成先（開発用ツリー起点）のリンクチェック ..."
"$CHECK" "$GEN_FROM_DEV" --label "generated (dev-origin)" "${STRICT_FLAG[@]}" || overall_status=$?

echo "[verify-tree-health] 生成先（公開用ツリー起点。第三者が実際に通る経路）のリンクチェック ..."
"$CHECK" "$GEN_FROM_PUBLIC" --label "generated (public-origin)" "${STRICT_FLAG[@]}" || overall_status=$?

echo "[verify-tree-health] 生成先どうしの差分（課題D: 起点ツリーによる成果物差） ..."
"$CHECK" --diff "$GEN_FROM_DEV" "$GEN_FROM_PUBLIC" --label "generated dev-origin vs public-origin" "${STRICT_FLAG[@]}" || overall_status=$?

if [[ $overall_status -ne 0 ]]; then
  echo "[verify-tree-health] 現状値を上記のとおり検出しました（--strict 指定時のみ非0で終了）"
fi
exit "$overall_status"
