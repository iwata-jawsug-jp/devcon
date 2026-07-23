#!/usr/bin/env bash
#
# cd-app.yml / cd-app-sandbox.yml が必要とするアプリ層のリポジトリ変数を、対象環境
# （dev/prod/sandbox）の infra/（アプリ層。infra/bootstrap/ ではない）terraform output
# から自動登録する。--clear を付けると逆に該当環境の12変数を削除する（#631: teardown後も
# 変数が残ると、実在しないAWSリソースを指したまま cd-app(-sandbox).yml の preflight が
# `configured=true` と誤判定し、build/frontend 段階の分かりにくいエラーで初めて気づく
# 事故が実際に起きた）。
#
# 対応表（docs/repository-variables.md「3. 本番アプリ用」「4. sandbox用」参照）:
#   prod    -> 接頭辞なし（例: ECR_REPOSITORY）  … cd-app.yml が消費
#   sandbox -> SANDBOX_ 接頭辞                    … cd-app-sandbox.yml が消費
#   dev     -> DEV_ 接頭辞                        … 現時点でこれを消費する workflow は
#                                                    無い（cd-app.yml は prod 専用、
#                                                    cd-app-sandbox.yml は SANDBOX_ 専用）。
#                                                    将来 cd-app-dev.yml 等を追加する
#                                                    ときのために前もって登録しておく
#                                                    予定枠（docs/repository-variables.md
#                                                    「5. dev用」参照）。
#
# これまで「対象環境の infra/ を apply した後、terraform output を見ながら
# gh variable set を12回手で打つ」という手順だったものを自動化する
# （infra/bootstrap/ 側の bootstrap.sh write と同じ動機・同じ発想）。
#
# 前提:
#   - 対象環境の infra/（アプリ層）が既に terraform apply 済みであること。
#   - 実行環境に対象AWSアカウントへの有効な認証情報があること
#     （docs/aws-temporary-credentials.md か tools/script/aws-sso-setup.sh）。
#   - リポジトリ変数 PROJECT_NAME / AWS_TF_STATE_BUCKET が登録済みであること
#     （通常は infra/bootstrap/ の bootstrap.sh write が自動登録する）。
#
# このスクリプト自体は読み取り専用（terraform init + output）で、apply/destroy は
# 一切行わない。ただし対象 backend を切り替えるため、infra/ 配下の .terraform（ローカルの
# バックエンド接続状態）を -reconfigure で書き換える点には注意
# （リモート state 自体は変更しない）。
#
# Usage:
#   ./tools/script/write-cd-app-vars.sh <dev|prod|sandbox> [-o org] [-r repo] [-y]
#   ./tools/script/write-cd-app-vars.sh <dev|prod|sandbox> --clear [-o org] [-r repo] [-y]
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
INFRA_DIR="infra"

usage() {
  cat <<'EOF'
Usage: write-cd-app-vars.sh <dev|prod|sandbox> [options]

対象環境の infra/（アプリ層）terraform output から、cd-app.yml / cd-app-sandbox.yml
（および将来の cd-app-dev.yml）が必要とするリポジトリ変数12個を登録する。
--clear を付けると、登録の代わりに該当環境の12変数を削除する（infra/env/ の terraform
output は読まない・AWS認証も不要）。terraform destroy 後に実行し、実在しないリソースを
指したままの変数が cd-app(-sandbox).yml の preflight を誤って通過させる事故（#631）を防ぐ。

Arguments:
  dev       DEV_ 接頭辞（現時点でどの workflow も消費しない予定枠）
  prod      接頭辞なし（cd-app.yml が消費）
  sandbox   SANDBOX_ 接頭辞（cd-app-sandbox.yml が消費）

Options:
  --clear             登録ではなく削除する（destroy後の後片付け用）
  -o, --org <org>     GitHub org（省略時は自動検出）
  -r, --repo <repo>   GitHub repo（省略時は自動検出）
  -y, --yes           確認プロンプトをスキップ
  -h, --help          このヘルプを表示

前提（登録時のみ、--clear では不要）:
  - 対象環境の infra/ が terraform apply 済みであること。
  - 実行環境に対象AWSアカウントへの有効な認証情報があること
    （docs/aws-temporary-credentials.md 参照）。
  - リポジトリ変数 PROJECT_NAME / AWS_TF_STATE_BUCKET が登録済みであること
    （通常 ./tools/script/bootstrap.sh write が自動登録する）。

書き込み権限のあるリポジトリ変数アクセスには、環境変数 GH_CHECK_SETUP_TOKEN /
.env.check-setup（ADR-0022、Variables: Read and write の PAT）があれば自動で使う。
無ければ gh の既定認証（≒ GH_TOKEN=<token> の明示指定）を使う。
EOF
}

# ---- 引数パース ----
env_name=""
org=""
repo=""
yes=false
clear_mode=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    dev | prod | sandbox)
      if [[ -n "$env_name" ]]; then
        echo "Error: 環境は1つだけ指定してください（既に '$env_name' 指定済み）。" >&2
        exit 2
      fi
      env_name="$1"
      shift
      ;;
    --clear) clear_mode=true; shift ;;
    -o | --org) org="${2:-}"; shift 2 ;;
    -r | --repo) repo="${2:-}"; shift 2 ;;
    -y | --yes) yes=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Error: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$env_name" ]]; then
  echo "Error: 環境を指定してください（dev|prod|sandbox）。" >&2
  usage
  exit 2
fi

case "$env_name" in
  dev) PREFIX="DEV_" ;;
  prod) PREFIX="" ;;
  sandbox) PREFIX="SANDBOX_" ;;
esac

# ---- GitHub org/repo 自動検出（bootstrap.sh と同じロジック）----
detect_github_org_repo() {
  if command -v gh >/dev/null 2>&1 && gh repo view --json owner,name >/dev/null 2>&1; then
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

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh 未ログインです。gh auth login を実行してください。" >&2
  exit 1
fi

if [[ -z "$org" || -z "$repo" ]]; then
  if detect_github_org_repo; then
    org="${org:-$DETECTED_ORG}"
    repo="${repo:-$DETECTED_REPO}"
  else
    echo "Error: GitHub org/repo を自動検出できませんでした。-o/-r で指定してください。" >&2
    exit 2
  fi
fi
echo "==> リポジトリ: $org/$repo"

# bootstrap.sh の cmd_write/resolve_published_values と同じトークン発見ロジック
# （ADR-0022）: 1) 環境変数が既にセット済みならそれを使う。2) 無ければ .env.check-setup
# を読む。優先順位・発見ロジックは変えない。
gh_check_setup_token="${GH_CHECK_SETUP_TOKEN:-}"
if [[ -z "$gh_check_setup_token" && -f .env.check-setup ]]; then
  gh_check_setup_token="$(grep -m1 '^GH_CHECK_SETUP_TOKEN=' .env.check-setup | cut -d= -f2-)"
fi
gh_t() {
  if [[ -n "$gh_check_setup_token" ]]; then
    GH_TOKEN="$gh_check_setup_token" gh "$@"
  else
    gh "$@"
  fi
}

# terraform output -> リポジトリ変数名のマッピング（登録・削除の両方で使う）。
# "変数名サフィックス|terraform output名|変換方法（raw/ecr_name/csv）"
# infra/outputs.tf の各 output に対応。定義を変更したら outputs.tf 側も更新すること。
MAPPINGS=(
  "ECR_REPOSITORY|ecr_repository_url|ecr_name"
  "ECS_TASK_FAMILY|ecs_task_family|raw"
  "ECS_CLUSTER|ecs_cluster_name|raw"
  "ECS_SERVICE|ecs_service_name|raw"
  "PRIVATE_SUBNET_IDS|private_subnet_ids|csv"
  "APP_SECURITY_GROUP_ID|app_security_group_id|raw"
  "WEB_BUCKET|web_bucket|raw"
  "CLOUDFRONT_DISTRIBUTION_ID|cloudfront_distribution_id|raw"
  "CLOUDFRONT_DOMAIN_NAME|cloudfront_domain_name|raw"
  "COGNITO_USER_POOL_ID|cognito_user_pool_id|raw"
  "COGNITO_CLIENT_ID|cognito_user_pool_client_id|raw"
  "COGNITO_DOMAIN|cognito_hosted_ui_domain_prefix|raw"
)
VAR_SUFFIXES=()
for entry in "${MAPPINGS[@]}"; do
  VAR_SUFFIXES+=("${entry%%|*}")
done

if $clear_mode; then
  echo
  echo "==> 環境: $env_name  接頭辞: '${PREFIX:-(なし)}'"
  echo "    ${org}/${repo} から以下の${#VAR_SUFFIXES[@]}個のリポジトリ変数を削除します"
  echo "    （terraform output は読まない・AWS認証は不要）:"
  printf '      - %s\n' "${VAR_SUFFIXES[@]/#/$PREFIX}"
  if ! $yes; then
    read -r -p "続行しますか？ [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || {
      echo "中止しました。"
      exit 1
    }
  fi

  deleted_count=0
  for suffix in "${VAR_SUFFIXES[@]}"; do
    var_name="${PREFIX}${suffix}"
    if gh_t variable delete "$var_name" --repo "$org/$repo" >/dev/null 2>&1; then
      echo "  [deleted] $var_name"
      deleted_count=$((deleted_count + 1))
    else
      # 既に未登録なら削除は失敗するが、目的（未登録状態）は既に満たされているので
      # 冪等に成功扱いとする。
      echo "  [skip] $var_name（既に未登録）"
    fi
  done
  echo
  echo "==> 完了: ${deleted_count}/${#VAR_SUFFIXES[@]}件 削除（残りは既に未登録でした）"
  exit 0
fi

# ---- 1. bootstrap配線変数（PROJECT_NAME / AWS_TF_STATE_BUCKET）を読む ----
# infra/（アプリ層）の backend.hcl をレンダリングするために必要
# （cd-infra.yml の「Materialize backend + tfvars from committed examples」と同じ）。
echo "==> リポジトリ変数から PROJECT_NAME / AWS_TF_STATE_BUCKET を取得します..."
project="$(gh_t variable get PROJECT_NAME --repo "$org/$repo" 2>/dev/null)" || project=""
bucket="$(gh_t variable get AWS_TF_STATE_BUCKET --repo "$org/$repo" 2>/dev/null)" || bucket=""
if [[ -z "$project" || -z "$bucket" ]]; then
  echo "Error: PROJECT_NAME / AWS_TF_STATE_BUCKET が未登録です。" >&2
  echo "       先に './tools/script/bootstrap.sh write' を実行してください。" >&2
  exit 1
fi
echo "==> project=$project state_bucket_name=$bucket"

# ---- 2. infra/env/<env>.backend.hcl をレンダリング ----
backend_example="$INFRA_DIR/env/${env_name}.backend.hcl.example"
backend_file="$INFRA_DIR/env/${env_name}.backend.hcl"
if [[ ! -f "$backend_example" ]]; then
  echo "Error: $backend_example が見つかりません。" >&2
  exit 1
fi
sed -e "s|REPLACE-ME-tfstate|$bucket|" \
  -e "s|devcon|$project|g" \
  "$backend_example" >"$backend_file"
echo "==> $backend_file を生成しました。"

echo
echo "==> 環境: $env_name  接頭辞: '${PREFIX:-(なし)}'"
echo "    infra/ を対象 backend（key=${project}/${env_name}/terraform.tfstate）で"
echo "    terraform init -reconfigure し、12個のリポジトリ変数を ${org}/${repo} へ登録します。"
echo "    （-reconfigure により infra/ のローカルbackend接続状態を切り替えます。リモート"
echo "     state自体は変更しません。他の環境向けにplan/apply作業中の場合は先に完了させること。）"
if ! $yes; then
  read -r -p "続行しますか？ [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || {
    echo "中止しました。"
    exit 1
  }
fi

tf() { terraform -chdir="$INFRA_DIR" "$@"; }
tf init -backend-config="env/${env_name}.backend.hcl" -reconfigure -input=false >/dev/null
echo "==> terraform init 完了。output を読み取ります..."

# ---- 3. terraform output をリポジトリ変数へ登録（MAPPINGS は冒頭で定義済み）----
failed=()
set_count=0
for entry in "${MAPPINGS[@]}"; do
  IFS='|' read -r var_suffix tf_output conv <<<"$entry"
  var_name="${PREFIX}${var_suffix}"
  value=""
  case "$conv" in
    raw)
      value="$(tf output -raw "$tf_output" 2>/dev/null)" || {
        failed+=("$tf_output")
        continue
      }
      ;;
    ecr_name)
      # ecr_repository_url は "<account>.dkr.ecr.<region>.amazonaws.com/<repo-name>"。
      # 登録するのはリポジトリ名のみ（docs/repository-variables.md の注記どおり）。
      url="$(tf output -raw "$tf_output" 2>/dev/null)" || {
        failed+=("$tf_output")
        continue
      }
      value="${url##*/}"
      ;;
    csv)
      # private_subnet_ids はリスト output。cd-app.yml の
      # `awsvpcConfiguration={subnets=[$SUBNETS],...}` にそのまま埋め込める形
      # （カンマ区切り・空白/角括弧なし）にする。
      value="$(tf output -json "$tf_output" 2>/dev/null | jq -r 'join(",")')" || {
        failed+=("$tf_output")
        continue
      }
      ;;
  esac
  if gh_t variable set "$var_name" --body "$value" --repo "$org/$repo" >/dev/null; then
    echo "  [ok] $var_name = $value"
    set_count=$((set_count + 1))
  else
    echo "  [FAIL] $var_name の登録に失敗しました" >&2
    failed+=("$var_name")
  fi
done

echo
echo "==> 完了: ${set_count}/${#MAPPINGS[@]}件 登録"

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "Error: 以下が取得または登録できませんでした:" >&2
  printf '    - %s\n' "${failed[@]}" >&2
  echo "       terraform -chdir=infra output で値を確認するか、対象環境の infra/ が" >&2
  echo "       apply 済みか確認してください。" >&2
  exit 1
fi

if [[ "$env_name" == "dev" ]]; then
  echo
  echo "Note: DEV_ 接頭辞のリポジトリ変数は、現時点ではどの workflow も消費していません"
  echo "      （cd-app.yml は prod 専用の接頭辞なし変数、cd-app-sandbox.yml は SANDBOX_"
  echo "      接頭辞のみ参照）。将来 cd-app-dev.yml 等を追加するときのための予定枠として"
  echo "      前もって登録しています（docs/repository-variables.md「5. dev用」参照）。"
fi
