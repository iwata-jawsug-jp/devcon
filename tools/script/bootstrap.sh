#!/usr/bin/env bash
#
# infra/bootstrap 初期設定・更新・書き込み・破棄スクリプト（#491）
#
# infra/bootstrap/README.md の「一度だけ・人力・ローカル state」の手作業
# （terraform apply への -var 手入力、gh variable set 3行のコピペ、
#  infra/env/*.backend.hcl / *.tfvars の手書き、destroy 手順が無い）を置き換える。
#
# サブコマンド:
#   init     - 初回のみ。GitHub org/repo・AWSアカウントIDを自動検出し、state バケット名を
#              `terraform-<project>-<account_id>-<random6>` として自動生成、既存の
#              GitHub Actions OIDC プロバイダーの有無も検出したうえで terraform apply する
#              （ローカル state。infra/bootstrap/terraform.auto.tfvars に解決した値を保存）。
#   update   - 2回目以降。terraform.auto.tfvars（無ければ既存 state から復元）を再利用し、
#              パラメータ指定なしで terraform apply するだけ（main.tf の IAM ポリシー変更等を
#              反映し忘れる事故 #488 を防ぐ）。
#   write    - terraform output の値を GitHub リポジトリ変数へ登録し、
#              infra/env/*.backend.hcl / *.tfvars を .example から生成する
#              （project名のプレースホルダ "devcon" は実際の project 名に置換する）。
#   destroy  - bootstrap で作成したリソースを破棄する。既定では state バケットと
#              GitHub Actions OIDC プロバイダーを対象外にする:
#                --include-state-bucket   prevent_destroy を一時解除して state バケットも破棄
#                                          （必ず main.tf を元に戻す）
#                --include-oidc-provider  このbootstrapが作成した（create_oidc_provider=true の）
#                                          OIDC プロバイダーも破棄する。同じAWSアカウントを
#                                          共有する他リポジトリの bootstrap が
#                                          create_oidc_provider=false でこれを再利用している
#                                          可能性があり、削除するとそちらのCI認証も壊れるため、
#                                          -y/--yes を指定しても必ず個別に確認する。
#
# Usage:
#   ./tools/script/bootstrap.sh init -p <project> [-o <org>] [-r <repo>] [-b <bucket>] [-y]
#   ./tools/script/bootstrap.sh update [-o <org>] [-r <repo>] [-y]
#   ./tools/script/bootstrap.sh write [--force]
#   ./tools/script/bootstrap.sh destroy [--include-state-bucket] [--include-oidc-provider] [-y]
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
BOOTSTRAP_DIR="infra/bootstrap"
TFVARS_FILE="$BOOTSTRAP_DIR/terraform.auto.tfvars"

usage() {
  cat <<'EOF'
Usage: bootstrap.sh <command> [options]

Commands:
  init      Bootstrap the state bucket / OIDC provider / CI IAM roles (first time only).
              -p, --project <name>       Project name (required, no default)
              -o, --org <org>            GitHub org (auto-detected if omitted)
              -r, --repo <repo>          GitHub repo (auto-detected if omitted)
              -b, --bucket-name <name>   State bucket name (auto-generated if omitted)
              -R, --region <region>      AWS region (default: ap-northeast-1)
              -y, --yes                  Skip the confirmation prompt

  update    Re-apply with the previously resolved values (no parameters required).
              -o, --org <org>            Override GitHub org
              -r, --repo <repo>          Override GitHub repo
              -y, --yes                  Skip the confirmation prompt

  write     Push bootstrap outputs to GitHub repo variables and materialize
            infra/env/*.backend.hcl / *.tfvars from their .example templates.
              --force                    Overwrite files that already exist

  destroy   Tear down bootstrap-created resources.
              --include-state-bucket     Also destroy the state bucket (destructive)
              --include-oidc-provider    Also destroy the OIDC provider, if this bootstrap
                                          created it (always asks separately, even with -y --
                                          other repos sharing this AWS account may reuse it)
              -y, --yes                  Skip the confirmation prompt

  -h, --help  Show this help
EOF
}

tf() { terraform -chdir="$BOOTSTRAP_DIR" "$@"; }

has_state() { [[ -n "$(tf state list 2>/dev/null)" ]]; }

confirm() {
  local yes="$1" prompt="$2"
  $yes && return 0
  local ans
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---- GitHub org/repo 自動検出 ----
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

detect_account_id() {
  command -v aws >/dev/null 2>&1 || { echo "Error: aws CLI not found." >&2; return 1; }
  aws sts get-caller-identity --query Account --output text 2>/dev/null
}

random6() { tr -dc 'a-z0-9' </dev/urandom | head -c6 || true; }

# IAM allows only one OIDC provider per URL per AWS account. If some other
# repo's bootstrap in the same account already created it, ours must reuse it
# instead of trying (and failing) to create a duplicate.
oidc_provider_exists() {
  aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[].Arn" --output text 2>/dev/null \
    | tr '\t' '\n' | grep -q "oidc-provider/token.actions.githubusercontent.com"
}

# Whether *this* bootstrap's state already manages the OIDC provider resource
# (present regardless of the moved-block refactor's [0] index or not).
state_has_oidc_resource() {
  tf state list 2>/dev/null | grep -q '^aws_iam_openid_connect_provider\.github'
}

write_tfvars() {
  local project="$1" org="$2" repo="$3" bucket="$4" region="$5" create_oidc="$6"
  cat >"$TFVARS_FILE" <<EOF
project              = "$project"
github_org           = "$org"
github_repo          = "$repo"
state_bucket_name    = "$bucket"
aws_region           = "$region"
create_oidc_provider = $create_oidc
EOF
}

# project 名は state から直接は取れない（project は output していない）ため、
# 既存の ci_plan_role_arn（"<project>-ci-plan" 命名、main.tf）から逆算する。
project_from_state() {
  local plan_arn role_name
  plan_arn="$(tf output -raw ci_plan_role_arn 2>/dev/null)" || return 1
  role_name="${plan_arn##*/}"
  echo "${role_name%-ci-plan}"
}

# ============================================================
# init
# ============================================================
cmd_init() {
  local project="" org="" repo="" bucket="" region="ap-northeast-1" yes=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p | --project) project="${2:-}"; shift 2 ;;
      -o | --org) org="${2:-}"; shift 2 ;;
      -r | --repo) repo="${2:-}"; shift 2 ;;
      -b | --bucket-name) bucket="${2:-}"; shift 2 ;;
      -R | --region) region="${2:-}"; shift 2 ;;
      -y | --yes) yes=true; shift ;;
      -h | --help) usage; exit 0 ;;
      *) echo "Error: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
  done

  if [[ -z "$project" ]]; then
    echo "Error: -p/--project is required (no default -- see docs/scaffold-cli.md)." >&2
    exit 2
  fi

  if has_state; then
    echo "Error: $BOOTSTRAP_DIR is already applied." >&2
    echo "       Use '$0 update' to re-apply the existing values, or '$0 destroy' to tear down first." >&2
    exit 1
  fi

  if [[ -z "$org" || -z "$repo" ]]; then
    if detect_github_org_repo; then
      org="${org:-$DETECTED_ORG}"
      repo="${repo:-$DETECTED_REPO}"
      echo "==> GitHub org/repo を自動検出: $org/$repo"
    else
      echo "Error: GitHub org/repo を自動検出できませんでした。-o/-r で指定してください。" >&2
      exit 2
    fi
  fi

  local account_id
  if ! account_id="$(detect_account_id)"; then
    echo "Error: AWSアカウントIDを取得できません。認証情報を設定してください（docs/aws-temporary-credentials.md 参照）。" >&2
    exit 1
  fi
  echo "==> AWSアカウントID: $account_id"

  if [[ -z "$bucket" ]]; then
    bucket="terraform-${project}-${account_id}-$(random6)"
    echo "==> state バケット名を生成: $bucket"
  fi

  local create_oidc=true
  if oidc_provider_exists; then
    create_oidc=false
    echo "==> このAWSアカウントには既にGitHub Actions OIDCプロバイダーが存在するため再利用します（新規作成しません）"
  fi

  echo
  echo "==> 以下の値で terraform apply します:"
  echo "      project              = $project"
  echo "      github_org           = $org"
  echo "      github_repo          = $repo"
  echo "      state_bucket_name    = $bucket"
  echo "      aws_region           = $region"
  echo "      create_oidc_provider = $create_oidc"
  echo

  confirm "$yes" "続行しますか？" || { echo "中止しました。"; exit 1; }

  write_tfvars "$project" "$org" "$repo" "$bucket" "$region" "$create_oidc"

  tf init
  # -auto-approve: the confirm() above already gated this; terraform still prints
  # the full plan below, it just skips its own redundant "yes" prompt.
  tf apply -auto-approve

  echo
  echo "==> 完了。次は './tools/script/bootstrap.sh write' でリポジトリ変数と infra/env/*.backend.hcl / *.tfvars を反映してください。"
}

# ============================================================
# update
# ============================================================
cmd_update() {
  local org="" repo="" yes=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o | --org) org="${2:-}"; shift 2 ;;
      -r | --repo) repo="${2:-}"; shift 2 ;;
      -y | --yes) yes=true; shift ;;
      -h | --help) usage; exit 0 ;;
      *) echo "Error: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
  done

  if ! has_state; then
    echo "Error: $BOOTSTRAP_DIR はまだ適用されていません。先に '$0 init' を実行してください。" >&2
    exit 1
  fi

  if [[ ! -f "$TFVARS_FILE" ]]; then
    echo "==> $TFVARS_FILE が無いため、既存の適用結果から復元します（$0 init を使わず手動 apply された環境向け）"

    local project bucket
    project="$(project_from_state)" || { echo "Error: project 名を state から復元できません。" >&2; exit 1; }
    bucket="$(tf output -raw state_bucket_name)"

    if [[ -z "$org" || -z "$repo" ]]; then
      detect_github_org_repo || {
        echo "Error: GitHub org/repo を自動検出できません。-o/-r で指定してください。" >&2
        exit 2
      }
      org="${org:-$DETECTED_ORG}"
      repo="${repo:-$DETECTED_REPO}"
    fi

    local create_oidc=true
    state_has_oidc_resource || create_oidc=false

    echo "==> 復元した値: project=$project github_org=$org github_repo=$repo state_bucket_name=$bucket create_oidc_provider=$create_oidc"
    write_tfvars "$project" "$org" "$repo" "$bucket" "ap-northeast-1" "$create_oidc"
  elif [[ -n "$org" || -n "$repo" ]]; then
    # 明示的な上書き指定があれば tfvars を書き換える（state_bucket_name/project は
    # 変更するとバケット replace を招くため update では受け付けない -- 変えたいなら
    # $TFVARS_FILE を直接編集すること）。
    local cur_project cur_bucket cur_region cur_create_oidc cur_org cur_repo
    tfvar() { grep -E "^$1[[:space:]]*=" "$TFVARS_FILE" | sed -E 's/^[^=]+=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'; }
    cur_project="$(tfvar project)"
    cur_org="$(tfvar github_org)"
    cur_repo="$(tfvar github_repo)"
    cur_bucket="$(tfvar state_bucket_name)"
    cur_region="$(tfvar aws_region)"
    cur_create_oidc="$(tfvar create_oidc_provider)"

    org="${org:-$cur_org}"
    repo="${repo:-$cur_repo}"
    echo "==> $TFVARS_FILE を更新します: github_org=$org github_repo=$repo（他の値は変更しません）"
    write_tfvars "$cur_project" "$org" "$repo" "$cur_bucket" "$cur_region" "$cur_create_oidc"
  fi

  echo "==> 既存の値（$TFVARS_FILE）を再利用して terraform apply します。"
  confirm "$yes" "続行しますか？" || { echo "中止しました。"; exit 1; }

  tf apply -auto-approve
}

# ============================================================
# write
# ============================================================
cmd_write() {
  local force=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=true; shift ;;
      -h | --help) usage; exit 0 ;;
      *) echo "Error: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
  done

  if ! has_state; then
    echo "Error: $BOOTSTRAP_DIR がまだ適用されていません。先に '$0 init' を実行してください。" >&2
    exit 1
  fi

  local bucket plan_arn deploy_arn project
  bucket="$(tf output -raw state_bucket_name)"
  plan_arn="$(tf output -raw ci_plan_role_arn)"
  deploy_arn="$(tf output -raw ci_deploy_role_arn)"
  project="$(project_from_state)" || { echo "Error: project 名を state から復元できません。" >&2; exit 1; }

  echo "==> project=$project state_bucket_name=$bucket"

  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    # gh variable set はリポジトリ変数への書き込み権限が要る。GitHub Codespaces の既定認証
    # （Codespaces注入の GITHUB_TOKEN）はこの権限を持たないことがあり（#516/#520）、失敗を
    # set -e で素通りさせるとこの後の infra/env/* 生成（GitHub とは無関係）まで巻き添えで
    # 止まってしまう。4件まとめて成否判定し、失敗してもスクリプトは継続させる。
    #
    # Codespaces上では gh auth login で再ログインしても解決しない（gh の認証優先順位は
    # GH_TOKEN > GITHUB_TOKEN > 保存済み認証情報で、Codespaces既定の GITHUB_TOKEN が常に
    # 保存済み認証情報より優先されるため）。書き込み権限のある PAT を GH_TOKEN として明示的に
    # 渡す必要がある。
    if gh variable set AWS_TF_STATE_BUCKET --body "$bucket" \
      && gh variable set AWS_PLAN_ROLE_ARN --body "$plan_arn" \
      && gh variable set AWS_DEPLOY_ROLE_ARN --body "$deploy_arn" \
      && gh variable set PROJECT_NAME --body "$project"; then
      echo "==> リポジトリ変数を設定しました: AWS_TF_STATE_BUCKET / AWS_PLAN_ROLE_ARN / AWS_DEPLOY_ROLE_ARN / PROJECT_NAME"
    else
      echo "==> リポジトリ変数の設定に失敗しました（権限不足の可能性）。GitHub Codespaces の既定認証には" >&2
      echo "    Actions Variables への書き込み権限が無いことがある。書き込み権限のある個人アクセストークンを" >&2
      echo "    GH_TOKEN=<token> ./tools/script/bootstrap.sh write のように指定して再実行するか、" >&2
      echo "    GitHub UI（Settings > Secrets and variables > Actions）から手動で登録してください。" >&2
    fi
  else
    echo "==> gh 未ログインのためリポジトリ変数の設定をスキップしました（gh auth login 後に再実行してください）" >&2
  fi

  local example real
  for example in infra/env/*.backend.hcl.example; do
    real="${example%.example}"
    if [[ -f "$real" && "$force" != true ]]; then
      echo "==> skip: $real（既に存在。上書きするには --force）"
      continue
    fi
    sed -e "s/REPLACE-ME-tfstate/$bucket/" \
      -e "s/devcon/$project/g" \
      "$example" >"$real"
    echo "==> generated: $real"
  done

  for example in infra/env/*.tfvars.example; do
    real="${example%.example}"
    if [[ -f "$real" && "$force" != true ]]; then
      echo "==> skip: $real（既に存在。上書きするには --force）"
      continue
    fi
    sed -e "s/devcon/$project/g" "$example" >"$real"
    echo "==> generated: $real"
  done
}

# ============================================================
# destroy
# ============================================================
cmd_destroy() {
  local include_bucket=false include_oidc=false yes=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --include-state-bucket) include_bucket=true; shift ;;
      --include-oidc-provider) include_oidc=true; shift ;;
      -y | --yes) yes=true; shift ;;
      -h | --help) usage; exit 0 ;;
      *) echo "Error: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
  done

  if ! has_state; then
    echo "Error: $BOOTSTRAP_DIR に破棄対象の state がありません。" >&2
    exit 1
  fi

  echo "==> state バケット・OIDCプロバイダー以外（ci_plan/ci_deployロールとそのポリシー）を破棄します。"
  confirm "$yes" "続行しますか？" || { echo "中止しました。"; exit 1; }

  local targets=(
    aws_iam_role_policy_attachment.ci_deploy_observability
    aws_iam_role_policy_attachment.ci_deploy_data
    aws_iam_role_policy_attachment.ci_deploy_auth
    aws_iam_role_policy_attachment.ci_deploy_storage_cdn
    aws_iam_role_policy_attachment.ci_deploy_iam
    aws_iam_role_policy_attachment.ci_deploy_compute
    aws_iam_role_policy_attachment.ci_deploy_network
    aws_iam_role_policy_attachment.ci_deploy_state
    aws_iam_policy.ci_deploy_observability
    aws_iam_policy.ci_deploy_data
    aws_iam_policy.ci_deploy_auth
    aws_iam_policy.ci_deploy_storage_cdn
    aws_iam_policy.ci_deploy_iam
    aws_iam_policy.ci_deploy_compute
    aws_iam_policy.ci_deploy_network
    aws_iam_policy.ci_deploy_state
    aws_iam_role_policy.ci_plan_access_analyzer
    aws_iam_role_policy.ci_plan_state
    aws_iam_role_policy_attachment.ci_plan_readonly
    aws_iam_role.ci_deploy
    aws_iam_role.ci_plan
  )
  local target_args=()
  for t in "${targets[@]}"; do target_args+=(-target="$t"); done
  tf destroy "${target_args[@]}" -auto-approve

  # OIDC プロバイダーは、このbootstrapが作成した場合（create_oidc_provider=true）のみ
  # 破棄対象になり得る。同じAWSアカウントを共有する他リポジトリのbootstrapが
  # create_oidc_provider=false でこれを再利用している可能性があるため、--include-oidc-provider
  # と -y/--yes の両方があっても、OIDC破棄だけは常に個別確認を挟む（-y ではスキップしない）。
  if state_has_oidc_resource; then
    if ! $include_oidc; then
      echo "==> OIDCプロバイダーはこのbootstrapが作成したものですが、対象外のまま残しました（削除するには --include-oidc-provider）。"
    else
      echo
      echo "!! GitHub Actions OIDCプロバイダー（token.actions.githubusercontent.com）はAWSアカウントに"
      echo "!! 1つしか存在できません。同じアカウントを共有する他リポジトリのbootstrapが"
      echo "!! create_oidc_provider=false でこれを再利用している場合、削除するとそちらのCI認証も壊れます。"
      read -r -p "OIDCプロバイダーも削除しますか？ [y/N] " oidc_ans
      if [[ "$oidc_ans" =~ ^[Yy]$ ]]; then
        tf destroy -target=aws_iam_openid_connect_provider.github -auto-approve
      else
        echo "==> OIDCプロバイダーは削除せず残しました。"
      fi
    fi
  else
    echo "==> OIDCプロバイダーはこのbootstrapが作成したものではない（他リポジトリ分を再利用中）ため、常に削除対象外です。"
  fi

  if ! $include_bucket; then
    echo "==> state バケットは対象外のまま残しました（削除するには --include-state-bucket）。"
    return
  fi

  local bucket
  bucket="$(tf output -raw state_bucket_name 2>/dev/null || true)"
  echo
  echo "!! --include-state-bucket が指定されました。state バケット '$bucket' を削除すると"
  echo "!! Terraform state の全履歴が失われ、復元できません。"
  read -r -p "削除するバケット名を入力して確認してください: " typed
  if [[ "$typed" != "$bucket" ]]; then
    echo "入力が一致しないため中止しました。"
    exit 1
  fi

  local main_tf="$BOOTSTRAP_DIR/main.tf"
  cp "$main_tf" "$main_tf.bak"
  # lifecycle { prevent_destroy = true } を一時的にコメントアウトする。
  sed -i.orig 's/prevent_destroy = true/prevent_destroy = false/' "$main_tf"
  restore_main_tf() { mv "$main_tf.bak" "$main_tf"; rm -f "$main_tf.orig"; }
  trap restore_main_tf EXIT

  tf destroy \
    -target=aws_s3_bucket_policy.state \
    -target=aws_s3_bucket_lifecycle_configuration.state \
    -target=aws_s3_bucket_public_access_block.state \
    -target=aws_s3_bucket_server_side_encryption_configuration.state \
    -target=aws_s3_bucket_versioning.state \
    -target=aws_s3_bucket.state \
    -auto-approve

  restore_main_tf
  trap - EXIT
  echo "==> main.tf を復元しました。"
}

# ============================================================
main() {
  local command="${1:-}"
  [[ $# -gt 0 ]] && shift

  case "$command" in
    init) cmd_init "$@" ;;
    update) cmd_update "$@" ;;
    write) cmd_write "$@" ;;
    destroy) cmd_destroy "$@" ;;
    -h | --help | "") usage; [[ -z "$command" ]] && exit 2 || exit 0 ;;
    *) echo "Error: unknown command: $command" >&2; usage; exit 2 ;;
  esac
}

main "$@"
