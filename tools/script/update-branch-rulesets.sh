#!/usr/bin/env bash
#
# main ブランチに適用する GitHub Ruleset（main-ci-required / sandbox-isolation）を、
# ci.yml・sandbox-guard.yml の必須ジョブ構成に合わせて作成・更新する。
#
# これまで docs/infrastructure.md「ブランチ保護（GitHub Rulesets）」・docs/sandbox.md
# 「GitHub ルールセット」に `gh api -X POST/PUT` の手順がコピペ用に書かれているだけで、
# 実行可能なスクリプトが無かった（#295 で required_status_checks のネスト構造は
# `-F 'rules[][...]'` のフラット展開では表現できないと判明済み — #27 で実際に
# 422 Invalid property /rules/N になった。JSON を組み立てて --input で渡す必要がある）。
#
# 対象は2つ（どちらも対象ブランチは ~DEFAULT_BRANCH。sandbox-isolation も「main への
# マージ時に強制する」ものであり、docs/sandbox.md の注記どおり ~ALL にはしないこと
# — sandbox-guard の guard ジョブは pull_request イベントでのみ起動するため、
# ~ALL だと新規ブランチの push 時点でチェック未実行のまま必須化され、リポジトリ全体で
# 新規ブランチの push がブロックされる障害が実際に起きている）:
#
#   main    -> main-ci-required（必須チェック: ci.yml のうちエリア別スイッチで skip
#              されうるが無関係なPRを待たせないべき横断ジョブを除いた5つ。
#              backend-go（BACKEND_GO_ENABLED でデフォルトskip）・scaffold・gen-types は
#              意図的に対象外。docs/infrastructure.md 本文・#295 / ADR-0012 参照）
#   sandbox -> sandbox-isolation（必須チェック: guard 1つ。sandbox-guard.yml が
#              sandbox/* ブランチからの非 sandbox/* へのマージを検出する。
#              docs/sandbox.md「GitHub ルールセット」参照）
#
# ci.yml / sandbox-guard.yml のジョブ構成を変えたら、下記 REQUIRED_CONTEXTS と
# docs/infrastructure.md・docs/sandbox.md の該当節・check-devenv-setup.sh の
# check_ruleset 呼び出しを合わせて更新すること。
#
# Usage:
#   ./tools/script/update-branch-rulesets.sh [-t main|sandbox|all] [-o org] [-r repo] [--dry-run] [-y]
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# target名 -> ruleset名 / 必須チェック一覧
ruleset_name_for() {
  case "$1" in
    main) echo "main-ci-required" ;;
    sandbox) echo "sandbox-isolation" ;;
  esac
}
ruleset_contexts_for() {
  case "$1" in
    main)
      printf '%s\n' "changes / check" "backend / check" "frontend / check" "infra / check" "scripts / check"
      ;;
    sandbox)
      printf '%s\n' "guard"
      ;;
  esac
}

usage() {
  cat <<'EOF'
Usage: update-branch-rulesets.sh [options]

main（~DEFAULT_BRANCH）に対する GitHub Ruleset を作成・更新する
（docs/infrastructure.md「ブランチ保護（GitHub Rulesets）」・docs/sandbox.md
「GitHub ルールセット」のスクリプト版）。既に存在すれば PUT で必須チェックを差し替え、
無ければ POST で新規作成する。

対象（-t で選択、省略時は all = 両方）:
  main      main-ci-required（ci.yml の必須ステータスチェック5つ）
  sandbox   sandbox-isolation（sandbox-guard の guard を必須化）
  all       上記両方（デフォルト）

Options:
  -t, --target <main|sandbox|all>  対象ルールセット（省略時 all）
  -o, --org <org>                  GitHub org（省略時は自動検出）
  -r, --repo <repo>                GitHub repo（省略時は自動検出）
  --dry-run                        実際には作成・更新せず、送信予定のJSONと現状の差分だけ表示する
  -y, --yes                        確認プロンプトをスキップ
  -h, --help                       このヘルプを表示

前提:
  - gh でログイン済みであること。
  - 対象リポジトリに対する admin 権限（rulesets の作成・更新には admin が必要。
    check-devenv-setup.sh / check-repo-vars.sh が使う GH_CHECK_SETUP_TOKEN
    （Variables: Read and write 用の限定PAT）ではスコープ不足のため、ここでは
    gh の既定認証をそのまま使う）。
EOF
}

target="all"
org=""
repo=""
dry_run=false
yes=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t | --target) target="${2:-}"; shift 2 ;;
    -o | --org) org="${2:-}"; shift 2 ;;
    -r | --repo) repo="${2:-}"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -y | --yes) yes=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Error: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$target" in
  main | sandbox) targets=("$target") ;;
  all) targets=("main" "sandbox") ;;
  *) echo "Error: -t/--target は main|sandbox|all のいずれかを指定してください（指定値: $target）。" >&2; exit 2 ;;
esac

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh 未ログインです。gh auth login を実行してください。" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq が必要です。" >&2
  exit 1
fi

# bootstrap.sh / write-cd-app-vars.sh と同じ org/repo 自動検出ロジック
detect_github_org_repo() {
  if gh repo view --json owner,name >/dev/null 2>&1; then
    DETECTED_ORG="$(gh repo view --json owner -q .owner.login)"
    DETECTED_REPO="$(gh repo view --json name -q .name)"
    return 0
  fi
  local url
  if url="$(git remote get-url origin 2>/dev/null)"; then
    if [[ "$url" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
      DETECTED_ORG="${BASH_REMATCH[1]}"
      DETECTED_REPO="${BASH_REMATCH[2]}"
      return 0
    fi
  fi
  return 1
}

if [[ -z "$org" || -z "$repo" ]]; then
  if detect_github_org_repo; then
    org="${org:-$DETECTED_ORG}"
    repo="${repo:-$DETECTED_REPO}"
  else
    echo "Error: GitHub org/repo を自動検出できませんでした。-o/-r で指定してください。" >&2
    exit 2
  fi
fi
repo_slug="$org/$repo"
echo "==> リポジトリ: $repo_slug"
echo "==> 対象: ${targets[*]}"

# ---- 各対象について送信するJSONを組み立て、現状との差分を表示する ----
# (グローバル配列。インデックスは targets と対応させる)
plan_names=()
plan_jsons=()
plan_ids=()
plan_actions=()

for t in "${targets[@]}"; do
  name="$(ruleset_name_for "$t")"
  mapfile -t contexts < <(ruleset_contexts_for "$t")

  contexts_json="$(printf '%s\n' "${contexts[@]}" | jq -R . | jq -s .)"
  ruleset_json="$(jq -n --arg name "$name" --argjson contexts "$contexts_json" '{
    name: $name,
    target: "branch",
    enforcement: "active",
    conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
    rules: [
      {
        type: "required_status_checks",
        parameters: {
          strict_required_status_checks_policy: false,
          do_not_enforce_on_create: false,
          required_status_checks: [$contexts[] | {context: .}]
        }
      }
    ]
  }')"

  echo
  echo "==> [$t] '$name' 必須ステータスチェック（送信予定）:"
  printf '    - %s\n' "${contexts[@]}"

  rs_id="$(gh api "repos/$repo_slug/rulesets" --jq ".[] | select(.name==\"$name\") | .id" 2>/dev/null || true)"
  if [[ -n "$rs_id" ]]; then
    echo "    既存の '$name'（id=$rs_id）を更新します。現在の必須チェック:"
    current_contexts="$(gh api "repos/$repo_slug/rulesets/$rs_id" \
      --jq '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context' 2>/dev/null || true)"
    if [[ -n "$current_contexts" ]]; then
      echo "$current_contexts" | sed 's/^/      - /'
    else
      echo "      (無し)"
    fi
    action="update"
  else
    echo "    '$name' は未作成です。新規作成します。"
    action="create"
  fi

  plan_names+=("$name")
  plan_jsons+=("$ruleset_json")
  plan_ids+=("$rs_id")
  plan_actions+=("$action")
done

if $dry_run; then
  echo
  echo "==> --dry-run のため送信しません。送信予定のJSON:"
  for i in "${!plan_names[@]}"; do
    echo "--- ${plan_names[$i]} ---"
    echo "${plan_jsons[$i]}" | jq .
  done
  exit 0
fi

if ! $yes; then
  echo
  read -r -p "続行しますか？ [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || {
    echo "中止しました。"
    exit 1
  }
fi

tmp_json="$(mktemp)"
trap 'rm -f "$tmp_json"' EXIT

for i in "${!plan_names[@]}"; do
  name="${plan_names[$i]}"
  echo "${plan_jsons[$i]}" >"$tmp_json"
  if [[ "${plan_actions[$i]}" == "update" ]]; then
    gh api -X PUT "repos/$repo_slug/rulesets/${plan_ids[$i]}" --input "$tmp_json" >/dev/null
    echo "==> [$name] 更新しました（id=${plan_ids[$i]}）。"
  else
    new_id="$(gh api -X POST "repos/$repo_slug/rulesets" --input "$tmp_json" --jq '.id')"
    echo "==> [$name] 作成しました（id=$new_id）。"
  fi
done
