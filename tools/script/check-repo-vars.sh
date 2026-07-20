#!/usr/bin/env bash
#
# リポジトリ変数（GitHub Actions vars.*）の整合性チェック
#
# docs/proposal/repository-variables-navigation-proposal.md Phase 2。
# 「workflow が実際に参照している変数」「docs/repository-variables.md に記載されている変数」
# 「実際に登録されている変数（gh variable list）」の3者を突き合わせ、ドリフト
# （ドキュメント漏れ・廃止済み記載の残り・登録忘れ・orphan登録）を検出する。
# check-devenv-setup.sh（bootstrap配線4個のみ）とは対象範囲が異なる — 本スクリプトは
# 全33変数を対象にした横断チェック。CI では使わない — ローカル/devcontainer 専用。
#
# Usage: ./tools/script/check-repo-vars.sh
#
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# check-devenv-setup.sh と同じ確認専用トークンの仕組みを再利用する（#516/#520。
# GitHub Codespaces の既定認証には Actions Variables の読み取り権限が無いことがある）。
# 優先順位（ADR-0021）: 1) 既に環境変数 GH_CHECK_SETUP_TOKEN がセット済み（GitHub
# Codespaces のユーザーシークレットからの自動注入を想定）ならそれを使う。
# 2) 無ければ .env.check-setup（非Codespaces向けフォールバック）を読む。
GH_CHECK_SETUP_TOKEN="${GH_CHECK_SETUP_TOKEN:-}"
if [[ -z "$GH_CHECK_SETUP_TOKEN" && -f .env.check-setup ]]; then
  GH_CHECK_SETUP_TOKEN="$(grep -m1 '^GH_CHECK_SETUP_TOKEN=' .env.check-setup | cut -d= -f2-)"
fi
gh_verify() {
  if [[ -n "$GH_CHECK_SETUP_TOKEN" ]]; then
    GH_TOKEN="$GH_CHECK_SETUP_TOKEN" gh "$@"
  else
    gh "$@"
  fi
}

# 環境変数も .env.check-setup も無いときの案内文（ADR-0021: Codespaces上ならユーザー
# シークレットを、そうでなければ .env.check-setup.example の手順を案内する）。
token_setup_hint() {
  if [[ "${CODESPACES:-}" == "true" ]]; then
    echo "GitHub Codespaces を使用中: github.com/settings/codespaces でユーザーシークレット GH_CHECK_SETUP_TOKEN（対象リポジトリ: このリポジトリ）を設定すると次回以降のCodespaceで自動判定できる（ADR-0021）。既存Codespaceには反映されないことがあり、その場合は再起動/再作成が必要"
  else
    echo ".env.check-setup.example を参照して確認用トークンを設定すると判定できる"
  fi
}

WARN=0
NG=0

section() { echo; echo "## $1"; }
ok()   { echo "  [OK] $1"; }
ng()   { echo "  [NG] $1"; [[ -n "${2:-}" ]] && echo "       -> $2"; NG=$((NG + 1)); }
warn() { echo "  [!!] $1"; [[ -n "${2:-}" ]] && echo "       -> $2"; WARN=$((WARN + 1)); }
info() { echo "  [--] $1"; }

DOC_FILE="docs/repository-variables.md"

# ---- カテゴリ定義（docs/repository-variables.md と対応させること）----
REQUIRED_VARS=(AWS_TF_STATE_BUCKET AWS_PLAN_ROLE_ARN AWS_DEPLOY_ROLE_ARN PROJECT_NAME)
SWITCH_VARS=(BACKEND_ENABLED FRONTEND_ENABLED INFRA_ENABLED INFRA_APPLY_ENABLED LIVE_SMOKE_ENABLED)
PROD_VARS=(ECR_REPOSITORY ECS_TASK_FAMILY ECS_CLUSTER ECS_SERVICE PRIVATE_SUBNET_IDS \
  APP_SECURITY_GROUP_ID WEB_BUCKET CLOUDFRONT_DISTRIBUTION_ID CLOUDFRONT_DOMAIN_NAME \
  COGNITO_USER_POOL_ID COGNITO_CLIENT_ID COGNITO_DOMAIN)
SANDBOX_VARS=(SANDBOX_ECR_REPOSITORY SANDBOX_ECS_TASK_FAMILY SANDBOX_ECS_CLUSTER SANDBOX_ECS_SERVICE \
  SANDBOX_PRIVATE_SUBNET_IDS SANDBOX_APP_SECURITY_GROUP_ID SANDBOX_WEB_BUCKET \
  SANDBOX_CLOUDFRONT_DISTRIBUTION_ID SANDBOX_CLOUDFRONT_DOMAIN_NAME SANDBOX_COGNITO_USER_POOL_ID \
  SANDBOX_COGNITO_CLIENT_ID SANDBOX_COGNITO_DOMAIN)

contains() {
  local needle="$1" x
  shift
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

# ---- 1. workflow が参照している変数（一次ソース）----
section "workflow参照の抽出"
if [[ ! -d .github/workflows ]]; then
  ng ".github/workflows が見つからない"
  exit 1
fi
workflow_vars="$(grep -rhoE 'vars\.[A-Z][A-Z0-9_]*' .github/workflows/*.yml | sed 's/^vars\.//' | sort -u)"
workflow_count=$(wc -l <<<"$workflow_vars")
ok "workflow参照: ${workflow_count}個"

# ---- 2. docs/repository-variables.md に記載されている変数 ----
if [[ ! -f "$DOC_FILE" ]]; then
  ng "$DOC_FILE が見つからない"
  exit 1
fi
# バッククォートで囲まれた大文字スネークケースの語を変数名として抽出。末尾が `_` の
# もの（例:「`SANDBOX_` プレフィックス」という説明文中の断片）は変数名ではないため除外。
doc_vars="$(grep -oE '`[A-Z][A-Z0-9_]*`' "$DOC_FILE" | tr -d '`' | grep -vE '_$' | sort -u)"
doc_count=$(wc -l <<<"$doc_vars")
ok "$DOC_FILE 記載: ${doc_count}個"

# ---- 3. 実際に登録されている変数 ----
registered_vars=""
registered_available=false
if gh auth status >/dev/null 2>&1; then
  if vars_raw="$(gh_verify variable list 2>&1)"; then
    registered_vars="$(awk '{print $1}' <<<"$vars_raw" | sort -u)"
    registered_available=true
    registered_count=$(grep -c . <<<"$registered_vars" || true)
    ok "登録済み変数: ${registered_count}個（gh variable list）"
  else
    info "リポジトリ変数の取得に失敗（権限不足の可能性）— 登録状況の突き合わせはスキップ"
    info "  -> $(token_setup_hint)"
  fi
else
  info "gh 未ログインのため登録状況の突き合わせはスキップ"
fi

# ---- 4. workflow ⇔ ドキュメント の突き合わせ ----
section "workflow参照 ⇔ ドキュメント記載"

missing_in_doc="$(comm -23 <(echo "$workflow_vars") <(echo "$doc_vars"))"
if [[ -z "$missing_in_doc" ]]; then
  ok "workflowが参照する変数はすべて $DOC_FILE に記載がある"
else
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    ng "$v はworkflowが参照しているが $DOC_FILE に記載が無い" "$DOC_FILE に追記すること"
  done <<<"$missing_in_doc"
fi

stale_in_doc="$(comm -13 <(echo "$workflow_vars") <(echo "$doc_vars"))"
if [[ -z "$stale_in_doc" ]]; then
  ok "$DOC_FILE に記載があってworkflowが参照していない変数は無い"
else
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    warn "$v は $DOC_FILE に記載があるが、どのworkflowも参照していない" "廃止済みなら $DOC_FILE から削除すること"
  done <<<"$stale_in_doc"
fi

# ---- 5. 登録状況（カテゴリ別）----
if [[ "$registered_available" == true ]]; then
  section "登録状況（bootstrap配線・必須4個）"
  for v in "${REQUIRED_VARS[@]}"; do
    if grep -qx "$v" <<<"$registered_vars"; then
      ok "$v 登録済み"
    else
      ng "$v が未登録" "./tools/script/bootstrap.sh write で登録（自分のAWSにデプロイしない場合は不要）"
    fi
  done

  section "登録状況（エリア別/オプトインスイッチ・任意5個）"
  for v in "${SWITCH_VARS[@]}"; do
    if grep -qx "$v" <<<"$registered_vars"; then
      info "$v 登録済み（docs/ci-cd-area-switches.md 参照）"
    else
      info "$v 未登録（デフォルト動作のまま。問題なし）"
    fi
  done

  section "登録状況（本番アプリ用・任意12個、本番インフラ未構築なら未登録が正常）"
  prod_registered=0
  for v in "${PROD_VARS[@]}"; do
    grep -qx "$v" <<<"$registered_vars" && prod_registered=$((prod_registered + 1))
  done
  if [[ "$prod_registered" -eq 0 ]]; then
    info "12個中0個登録（本番用インフラ未構築のため想定どおり）"
  elif [[ "$prod_registered" -eq ${#PROD_VARS[@]} ]]; then
    ok "12個中12個すべて登録済み"
  else
    warn "12個中${prod_registered}個のみ登録（全部か0個かのどちらかを想定。中途半端な状態は設定ミスの可能性）" \
      "未登録分: $(for v in "${PROD_VARS[@]}"; do grep -qx "$v" <<<"$registered_vars" || echo -n "$v "; done)"
  fi

  section "登録状況（sandbox用・任意12個）"
  sandbox_registered=0
  for v in "${SANDBOX_VARS[@]}"; do
    grep -qx "$v" <<<"$registered_vars" && sandbox_registered=$((sandbox_registered + 1))
  done
  if [[ "$sandbox_registered" -eq ${#SANDBOX_VARS[@]} ]]; then
    ok "12個中12個すべて登録済み"
  elif [[ "$sandbox_registered" -eq 0 ]]; then
    info "12個中0個登録（sandbox環境を使っていなければ想定どおり）"
  else
    warn "12個中${sandbox_registered}個のみ登録（全部か0個かのどちらかを想定。中途半端な状態は設定ミスの可能性）" \
      "未登録分: $(for v in "${SANDBOX_VARS[@]}"; do grep -qx "$v" <<<"$registered_vars" || echo -n "$v "; done)"
  fi

  # ---- 6. 登録済みだがworkflowが参照していない変数（orphan）----
  section "登録済み ⇔ workflow参照（orphan検出）"
  orphan="$(comm -23 <(echo "$registered_vars") <(echo "$workflow_vars"))"
  if [[ -z "$orphan" ]]; then
    ok "登録済みでworkflowが参照していない変数は無い"
  else
    while IFS= read -r v; do
      [[ -z "$v" ]] && continue
      warn "$v は登録されているが、どのworkflowも参照していない" "使われなくなった変数なら gh variable delete $v で削除を検討"
    done <<<"$orphan"
  fi
fi

# ---- サマリ ----
section "サマリ"
echo "  NG: $NG / 注意: $WARN"
