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
#              成功後、state バケット自身の中に terraform.tfstate / terraform.auto.tfvars を
#              自動バックアップする（後述、recover 参照）。
#   update   - 2回目以降。terraform.auto.tfvars（無ければ既存 state から復元）を再利用し、
#              パラメータ指定なしで terraform apply するだけ（main.tf の IAM ポリシー変更等を
#              反映し忘れる事故 #488 を防ぐ）。成功後、init と同じくバックアップを自動更新する。
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
#   adopt    - 別の開発PC（このリポジトリの `init` を実行していないマシン）で、既に他のPCで
#              適用済みの bootstrap 設定を使えるようにする。ローカル state は作らない
#              （state は `init` を実行した1台のマシンだけが持つ設計 — README「一度だけ・
#              人力・ローカル state」参照）。リポジトリ変数（PROJECT_NAME /
#              AWS_TF_STATE_BUCKET / AWS_PLAN_ROLE_ARN / AWS_DEPLOY_ROLE_ARN。`write` が
#              登録済みのはず）を読み、現在のAWS認証情報に対して実リソース（state バケット・
#              IAMロール3つ ※ci_plan/ci_deployはARNから、agent-mcpは"<project>-<suffix>-agent-mcp"
#              （suffixはci_plan/ci_deployのARNから逆算）という決定的な名前から判定 -- #571、
#              agent-mcpのARNはリポジトリ変数に載せない）が実在するか
#              確認したうえで、infra/env/*.backend.hcl / *.tfvars を生成する。`update`/`destroy`
#              はローカル state が要るため、引き続き `init` を実行した元のマシンから行うこと。
#   recover  - `init` を実行したマシン自体（＝ローカル state を持つ唯一のマシン）が失われた
#              場合に state を作り直す。ローカルに state が無い場合、まず state バケット内の
#              バックアップ（init/update/recover が自動更新）からの復元を試みる（S3から
#              terraform.tfstate / terraform.auto.tfvars を取得するだけなので、import より
#              高速・確実 -- apply時点のメタデータもそのまま復元できる）。バックアップが無い
#              /壊れている場合（または --no-restore 指定時）は、`adopt` と同じリポジトリ変数を
#              読んで対象を特定・実在確認したあと、`terraform import` を main.tf の全
#              managed resource（S3 state バケット一式 + IAMロール/ポリシー/アタッチメント）
#              に対して実行し、terraform.auto.tfvars も書く（このフォールバック経路のみ、
#              完了後にバックアップも更新する）。OIDCプロバイダーは所有権がAWS側から判別
#              できないため、既定では import しない（`--owns-oidc-provider` を指定した場合
#              のみ）。既に import 済みのリソースはスキップするため、一部失敗しても再実行
#              すれば再開できる。完了後は `terraform plan` で差分が無いことを確認すること。
#
# Usage:
#   ./tools/script/bootstrap.sh init -p <project> [-o <org>] [-r <repo>] [-b <bucket>] [-y]
#   ./tools/script/bootstrap.sh update [-o <org>] [-r <repo>] [-y]
#   ./tools/script/bootstrap.sh write [--force]
#   ./tools/script/bootstrap.sh destroy [--include-state-bucket] [--include-oidc-provider] [-y]
#   ./tools/script/bootstrap.sh adopt [-p <project>] [-b <bucket>] [--plan-role-arn <arn>]
#                                      [--deploy-role-arn <arn>] [-o <org>] [-r <repo>] [--force]
#   ./tools/script/bootstrap.sh recover [-p <project>] [-b <bucket>] [--plan-role-arn <arn>]
#                                        [--deploy-role-arn <arn>] [-o <org>] [-r <repo>]
#                                        [--owns-oidc-provider] [-R <region>] [--no-restore] [-y]
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
BOOTSTRAP_DIR="infra/bootstrap"
TFVARS_FILE="$BOOTSTRAP_DIR/terraform.auto.tfvars"
# state バケット内でバックアップを置くキー接頭辞。アプリ層のstate key（"${project}/<env>/..."）
# や ci_plan の読み取り許可プレフィックス（"${project}/dev/*"）と衝突しないよう、
# プロジェクト名を含まない固定の別名前空間にする。
BACKUP_PREFIX="_bootstrap-state-backup"

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

  adopt     Adopt bootstrap config already applied from another machine (no local Terraform
            state is created here -- run 'update'/'destroy' from the machine that ran 'init').
            Reads repo variables published by 'write' (override any of them with the flags
            below), verifies the referenced AWS resources actually exist under the current
            AWS credentials, then materializes infra/env/*.backend.hcl / *.tfvars.
              -p, --project <name>            Project name (default: repo var PROJECT_NAME)
              -b, --bucket-name <name>        State bucket (default: repo var AWS_TF_STATE_BUCKET)
              --plan-role-arn <arn>           (default: repo var AWS_PLAN_ROLE_ARN)
              --deploy-role-arn <arn>         (default: repo var AWS_DEPLOY_ROLE_ARN)
              -o, --org <org>                 GitHub org (auto-detected if omitted)
              -r, --repo <repo>               GitHub repo (auto-detected if omitted)
              --force                         Overwrite infra/env files that already exist

  recover   Rebuild local Terraform state when the machine that ran 'init' (and its local
            state) was lost. First tries restoring terraform.tfstate / terraform.auto.tfvars
            from the automatic backup inside the state bucket (fast, exact -- no import
            needed). Falls back to importing the still-existing AWS resources if no backup
            is found (or --no-restore is given): reads the same repo variables as 'adopt'
            (override with the same flags), verifies they exist, then runs 'terraform import'
            for every resource main.tf declares and writes terraform.auto.tfvars. Safe to
            re-run -- already-imported resources are skipped.
              -p, --project <name>            Project name (default: repo var PROJECT_NAME)
              -b, --bucket-name <name>        State bucket (default: repo var AWS_TF_STATE_BUCKET)
              --plan-role-arn <arn>           (default: repo var AWS_PLAN_ROLE_ARN)
              --deploy-role-arn <arn>         (default: repo var AWS_DEPLOY_ROLE_ARN)
              --owns-oidc-provider            Only set this if you're sure THIS bootstrap
                                               originally created the GitHub OIDC provider (not
                                               a sibling repo's bootstrap reusing it) -- also
                                               imports it. Default: false (looked up via data
                                               source, not imported -- the safe choice when unsure)
              --no-restore                    Skip the S3 backup restore attempt and go
                                               straight to the import-based fallback (use if
                                               the backup is known stale/corrupt)
              -o, --org <org>                 GitHub org (auto-detected if omitted)
              -r, --repo <repo>               GitHub repo (auto-detected if omitted)
              -R, --region <region>           AWS region (default: ap-northeast-1)
              -y, --yes                       Skip the confirmation prompt

  -h, --help  Show this help
EOF
}

tf() { terraform -chdir="$BOOTSTRAP_DIR" "$@"; }

has_state() { [[ -n "$(tf state list 2>/dev/null)" ]]; }

# state バケット自身の中（BACKUP_PREFIX、main.tf管理外の名前空間）へ terraform.tfstate /
# terraform.auto.tfvars をバックアップする。init/update成功後、recoverのimportフォールバック
# 完了後に自動で呼ぶ。失敗してもバックアップだけの問題なので致命扱いにしない
# （gh variable set失敗時と同じ方針 -- 権限不足等で失敗してもスクリプト自体は成功させる）。
backup_state() {
  local bucket
  bucket="$(tf output -raw state_bucket_name 2>/dev/null)" || {
    echo "WARN: state_bucket_name を取得できずバックアップをスキップしました。" >&2
    return 0
  }

  echo "==> state を s3://${bucket}/${BACKUP_PREFIX}/ へバックアップします..."
  if aws s3 cp "$BOOTSTRAP_DIR/terraform.tfstate" "s3://${bucket}/${BACKUP_PREFIX}/terraform.tfstate" >/dev/null \
    && aws s3 cp "$TFVARS_FILE" "s3://${bucket}/${BACKUP_PREFIX}/terraform.auto.tfvars" >/dev/null; then
    echo "==> バックアップ完了（バケットのバージョニングにより、上書きしても過去バージョンから復元可能）。"
  else
    echo "WARN: state のバックアップに失敗しました（S3への書き込み権限等を確認してください）。" >&2
    echo "      apply/import 自体は成功しているので、このマシンでの作業は続行できる。" >&2
  fi
}

# state バケット内のバックアップから terraform.tfstate / terraform.auto.tfvars を復元する。
# 成功したら 0 を返し、呼び出し側（recover）は import 一式を丸ごとスキップできる。
# バックアップが無い、またはダウンロードに失敗した場合は何もローカルに書かず 1 を返す
# （呼び出し側は既存の import ベースの復旧にフォールバックする）。
try_restore_from_backup() {
  local bucket="$1"

  if ! aws s3api head-object --bucket "$bucket" --key "${BACKUP_PREFIX}/terraform.tfstate" >/dev/null 2>&1; then
    echo "==> S3バックアップが見つかりません（s3://${bucket}/${BACKUP_PREFIX}/terraform.tfstate）。"
    return 1
  fi

  echo "==> S3バックアップが見つかりました: s3://${bucket}/${BACKUP_PREFIX}/ -- ダウンロードして復元します"
  echo "    （importベースの復旧より高速・確実なので、こちらを優先します）。"

  local tmp_state tmp_tfvars
  tmp_state="$(mktemp)"
  tmp_tfvars="$(mktemp)"
  if ! aws s3 cp "s3://${bucket}/${BACKUP_PREFIX}/terraform.tfstate" "$tmp_state" >/dev/null \
    || ! aws s3 cp "s3://${bucket}/${BACKUP_PREFIX}/terraform.auto.tfvars" "$tmp_tfvars" >/dev/null; then
    echo "WARN: バックアップのダウンロードに失敗しました。importベースの復旧にフォールバックします。" >&2
    rm -f "$tmp_state" "$tmp_tfvars"
    return 1
  fi

  mv "$tmp_state" "$BOOTSTRAP_DIR/terraform.tfstate"
  mv "$tmp_tfvars" "$TFVARS_FILE"
  tf init

  echo
  echo "==> 復元完了。バックアップ後にAWS側だけ変更されていないか、必ず差分を確認すること:"
  echo "      terraform -chdir=$BOOTSTRAP_DIR plan"
  return 0
}

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
  local project="$1" org="$2" repo="$3" bucket="$4" region="$5" create_oidc="$6" suffix="$7"
  cat >"$TFVARS_FILE" <<EOF
project               = "$project"
github_org            = "$org"
github_repo           = "$repo"
state_bucket_name     = "$bucket"
aws_region            = "$region"
create_oidc_provider  = $create_oidc
resource_name_suffix  = "$suffix"
EOF
}

# project 名は state から直接は取れない（project は output していない）ため、
# 既存の ci_plan_role_arn（"<project>-<suffix>-ci-plan" 命名、main.tf の local.name_prefix、
# #571）から逆算する。resource_name_suffix は output 済みなのでそちらから取り、
# "-<suffix>-ci-plan" を丸ごと剥がした残りが project。
project_from_state() {
  local plan_arn role_name suffix
  plan_arn="$(tf output -raw ci_plan_role_arn 2>/dev/null)" || return 1
  suffix="$(tf output -raw resource_name_suffix 2>/dev/null)" || return 1
  role_name="${plan_arn##*/}"
  echo "${role_name%-"$suffix"-ci-plan}"
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

  # IAMロール/ポリシー名（"<project>-<suffix>-ci-plan"等、main.tf の local.name_prefix、
  # #571）の一意化トークン。bucket が自動生成の場合は同じ値を使う（=「stateバケットと同じ
  # ランダム接尾辞」）。-b で bucket 名を明示指定した場合でも、IAMリソース名の一意化自体は
  # 引き続き必要なので suffix は常に新規生成する。
  local suffix
  suffix="$(random6)"

  if [[ -z "$bucket" ]]; then
    bucket="terraform-${project}-${account_id}-${suffix}"
    echo "==> state バケット名を生成: $bucket"
  fi

  local create_oidc=true
  if oidc_provider_exists; then
    create_oidc=false
    echo "==> このAWSアカウントには既にGitHub Actions OIDCプロバイダーが存在するため再利用します（新規作成しません）"
  fi

  echo
  echo "==> 以下の値で terraform apply します:"
  echo "      project               = $project"
  echo "      github_org            = $org"
  echo "      github_repo           = $repo"
  echo "      state_bucket_name     = $bucket"
  echo "      aws_region            = $region"
  echo "      create_oidc_provider  = $create_oidc"
  echo "      resource_name_suffix  = $suffix"
  echo

  confirm "$yes" "続行しますか？" || { echo "中止しました。"; exit 1; }

  write_tfvars "$project" "$org" "$repo" "$bucket" "$region" "$create_oidc" "$suffix"

  tf init
  # -auto-approve: the confirm() above already gated this; terraform still prints
  # the full plan below, it just skips its own redundant "yes" prompt.
  tf apply -auto-approve
  backup_state

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

    local project bucket suffix
    project="$(project_from_state)" || { echo "Error: project 名を state から復元できません。" >&2; exit 1; }
    bucket="$(tf output -raw state_bucket_name)"
    suffix="$(tf output -raw resource_name_suffix)" || { echo "Error: resource_name_suffix を state から復元できません。" >&2; exit 1; }

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

    echo "==> 復元した値: project=$project github_org=$org github_repo=$repo state_bucket_name=$bucket create_oidc_provider=$create_oidc resource_name_suffix=$suffix"
    write_tfvars "$project" "$org" "$repo" "$bucket" "ap-northeast-1" "$create_oidc" "$suffix"
  elif [[ -n "$org" || -n "$repo" ]]; then
    # 明示的な上書き指定があれば tfvars を書き換える（state_bucket_name/project/
    # resource_name_suffix は変更するとリソース replace を招くため update では受け付けない
    # -- 変えたいなら $TFVARS_FILE を直接編集すること）。
    local cur_project cur_bucket cur_region cur_create_oidc cur_org cur_repo cur_suffix
    tfvar() { grep -E "^$1[[:space:]]*=" "$TFVARS_FILE" | sed -E 's/^[^=]+=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'; }
    cur_project="$(tfvar project)"
    cur_org="$(tfvar github_org)"
    cur_repo="$(tfvar github_repo)"
    cur_bucket="$(tfvar state_bucket_name)"
    cur_region="$(tfvar aws_region)"
    cur_create_oidc="$(tfvar create_oidc_provider)"
    cur_suffix="$(tfvar resource_name_suffix)"

    org="${org:-$cur_org}"
    repo="${repo:-$cur_repo}"
    echo "==> $TFVARS_FILE を更新します: github_org=$org github_repo=$repo（他の値は変更しません）"
    write_tfvars "$cur_project" "$org" "$repo" "$cur_bucket" "$cur_region" "$cur_create_oidc" "$cur_suffix"
  fi

  echo "==> 既存の値（$TFVARS_FILE）を再利用して terraform apply します。"
  confirm "$yes" "続行しますか？" || { echo "中止しました。"; exit 1; }

  tf apply -auto-approve
  backup_state
}

# infra/env/*.backend.hcl / *.tfvars を .example から生成する（write / adopt 共通）。
materialize_env_files() {
  local project="$1" bucket="$2" force="$3"
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

  materialize_env_files "$project" "$bucket" "$force"
}

# 他の開発PCで `write` が登録したリポジトリ変数から project/bucket/plan_arn/deploy_arn を
# 読む（-p/-b/--plan-role-arn/--deploy-role-arn で明示済みの値はそのまま使う）。
# adopt / recover 共通。解決した値は RESOLVED_PROJECT / RESOLVED_BUCKET / RESOLVED_PLAN_ARN /
# RESOLVED_DEPLOY_ARN に入る。
resolve_published_values() {
  local project="$1" bucket="$2" plan_arn="$3" deploy_arn="$4" org="$5" repo="$6"

  if [[ -z "$project" || -z "$bucket" || -z "$plan_arn" || -z "$deploy_arn" ]]; then
    if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
      echo "Error: gh 未ログインのためリポジトリ変数を読めません。" >&2
      echo "       gh auth login するか、-p/-b/--plan-role-arn/--deploy-role-arn で明示指定してください。" >&2
      exit 2
    fi
    echo "==> $org/$repo のリポジトリ変数から未指定分を取得します..."
    gh_var() { gh variable get "$1" --repo "$org/$repo" 2>/dev/null; }
    [[ -z "$project" ]] && project="$(gh_var PROJECT_NAME)"
    [[ -z "$bucket" ]] && bucket="$(gh_var AWS_TF_STATE_BUCKET)"
    [[ -z "$plan_arn" ]] && plan_arn="$(gh_var AWS_PLAN_ROLE_ARN)"
    [[ -z "$deploy_arn" ]] && deploy_arn="$(gh_var AWS_DEPLOY_ROLE_ARN)"
  fi

  local missing=""
  [[ -z "$project" ]] && missing="$missing PROJECT_NAME(-p/--project)"
  [[ -z "$bucket" ]] && missing="$missing AWS_TF_STATE_BUCKET(-b/--bucket-name)"
  [[ -z "$plan_arn" ]] && missing="$missing AWS_PLAN_ROLE_ARN(--plan-role-arn)"
  [[ -z "$deploy_arn" ]] && missing="$missing AWS_DEPLOY_ROLE_ARN(--deploy-role-arn)"
  if [[ -n "$missing" ]]; then
    echo "Error: 値を決定できませんでした:$missing" >&2
    echo "       bootstrap を適用した側のマシンで '$0 write' を実行してリポジトリ変数へ登録するか、" >&2
    echo "       このコマンドに値を直接指定してください。" >&2
    exit 1
  fi

  RESOLVED_PROJECT="$project"
  RESOLVED_BUCKET="$bucket"
  RESOLVED_PLAN_ARN="$plan_arn"
  RESOLVED_DEPLOY_ARN="$deploy_arn"
}

# state バケットと ci_plan/ci_deploy/agent_mcp ロールが、現在のAWS認証情報から実際に見えるか
# 確認する（リポジトリ変数の値をそのまま信用しない -- 想定と違うAWSアカウントに繋いでいる事故を
# 防ぐ）。問題があれば理由を表示して exit 1 する。adopt / recover 共通。
verify_aws_resources() {
  local bucket="$1" plan_arn="$2" deploy_arn="$3" account_id="$4" project="$5"

  echo
  echo "==> AWS環境を確認します..."
  local problems=""

  local arn arn_account
  for arn in "$plan_arn" "$deploy_arn"; do
    arn_account="${arn#arn:aws:iam::}"
    arn_account="${arn_account%%:*}"
    if [[ "$arn_account" != "$account_id" ]]; then
      problems="${problems}    - $arn のAWSアカウントID（$arn_account）が現在の認証情報のアカウント（$account_id）と一致しません
"
    fi
  done

  if [[ -z "$problems" ]]; then
    if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
      echo "  [OK] state バケット '$bucket' が存在し、アクセスできます"
    else
      problems="${problems}    - state バケット '$bucket' が見つからない、またはアクセスできません
"
    fi

    local plan_role_name="${plan_arn##*/}" deploy_role_name="${deploy_arn##*/}"
    if aws iam get-role --role-name "$plan_role_name" >/dev/null 2>&1; then
      echo "  [OK] IAMロール '$plan_role_name'（ci_plan）が存在します"
    else
      problems="${problems}    - IAMロール '$plan_role_name'（ci_plan_role_arn）が見つかりません
"
    fi
    if aws iam get-role --role-name "$deploy_role_name" >/dev/null 2>&1; then
      echo "  [OK] IAMロール '$deploy_role_name'（ci_deploy）が存在します"
    else
      problems="${problems}    - IAMロール '$deploy_role_name'（ci_deploy_role_arn）が見つかりません
"
    fi

    # agent_mcp（#571）はCIから使わないためリポジトリ変数にARNを載せていない。名前は
    # main.tfのlocal.name_prefix（"${project}-${resource_name_suffix}"）と同じ規則で決定的
    # なので、project + suffix から直接組み立てる。suffixはresource_name_suffixとして
    # output済みだが、adopt/recoverはこの時点でまだterraform stateを持たない（recoverはこれ
    # から作る最中、adoptはそもそも作らない）ため output を読めない -- 代わりに
    # plan_role_name（"<project>-<suffix>-ci-plan"）から逆算する（suffixはrandom6で常に
    # 6文字固定）。
    local plan_name_without_role="${plan_role_name%-ci-plan}"
    local suffix="${plan_name_without_role: -6}"
    local agent_mcp_role_name="${project}-${suffix}-agent-mcp"
    if aws iam get-role --role-name "$agent_mcp_role_name" >/dev/null 2>&1; then
      echo "  [OK] IAMロール '$agent_mcp_role_name'（agent_mcp）が存在します"
    else
      problems="${problems}    - IAMロール '$agent_mcp_role_name'（agent_mcp）が見つかりません
"
    fi
  fi

  if [[ -n "$problems" ]]; then
    echo
    echo "Error: AWS環境の確認に失敗しました:" >&2
    echo -n "$problems" >&2
    echo "       他の開発PCの bootstrap 適用と、現在このマシンで使っているAWS認証情報が" >&2
    echo "       同じAWSアカウントを指しているか確認してください。" >&2
    exit 1
  fi
}

# ============================================================
# adopt
# ============================================================
cmd_adopt() {
  local project="" org="" repo="" bucket="" plan_arn="" deploy_arn="" force=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p | --project) project="${2:-}"; shift 2 ;;
      -o | --org) org="${2:-}"; shift 2 ;;
      -r | --repo) repo="${2:-}"; shift 2 ;;
      -b | --bucket-name) bucket="${2:-}"; shift 2 ;;
      --plan-role-arn) plan_arn="${2:-}"; shift 2 ;;
      --deploy-role-arn) deploy_arn="${2:-}"; shift 2 ;;
      --force) force=true; shift ;;
      -h | --help) usage; exit 0 ;;
      *) echo "Error: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
  done

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
  echo "==> AWSアカウントID（現在の認証情報）: $account_id"

  resolve_published_values "$project" "$bucket" "$plan_arn" "$deploy_arn" "$org" "$repo"
  project="$RESOLVED_PROJECT"; bucket="$RESOLVED_BUCKET"
  plan_arn="$RESOLVED_PLAN_ARN"; deploy_arn="$RESOLVED_DEPLOY_ARN"

  echo "==> project=$project state_bucket_name=$bucket"
  echo "    ci_plan_role_arn=$plan_arn"
  echo "    ci_deploy_role_arn=$deploy_arn"

  verify_aws_resources "$bucket" "$plan_arn" "$deploy_arn" "$account_id" "$project"

  echo
  echo "==> AWS環境の確認が完了しました。infra/env/*.backend.hcl / *.tfvars を生成します。"
  materialize_env_files "$project" "$bucket" "$force"

  echo
  echo "==> 完了。このマシンにはローカル Terraform state を作っていません"
  echo "    （state は '$0 init'（または '$0 recover'）を実行した1台のマシンだけが持つ設計）。"
  echo "    infra/bootstrap 自体の update/destroy は、そちらのマシンから実行してください。"
  echo "    元のマシンの state 自体が失われている場合は '$0 recover' を使ってください。"
}

# ============================================================
# recover
# ============================================================
cmd_recover() {
  local project="" org="" repo="" bucket="" plan_arn="" deploy_arn=""
  local region="ap-northeast-1" owns_oidc=false yes=false no_restore=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p | --project) project="${2:-}"; shift 2 ;;
      -o | --org) org="${2:-}"; shift 2 ;;
      -r | --repo) repo="${2:-}"; shift 2 ;;
      -b | --bucket-name) bucket="${2:-}"; shift 2 ;;
      --plan-role-arn) plan_arn="${2:-}"; shift 2 ;;
      --deploy-role-arn) deploy_arn="${2:-}"; shift 2 ;;
      --owns-oidc-provider) owns_oidc=true; shift ;;
      --no-restore) no_restore=true; shift ;;
      -R | --region) region="${2:-}"; shift 2 ;;
      -y | --yes) yes=true; shift ;;
      -h | --help) usage; exit 0 ;;
      *) echo "Error: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
  done

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
  echo "==> AWSアカウントID（現在の認証情報）: $account_id"

  resolve_published_values "$project" "$bucket" "$plan_arn" "$deploy_arn" "$org" "$repo"
  project="$RESOLVED_PROJECT"; bucket="$RESOLVED_BUCKET"
  plan_arn="$RESOLVED_PLAN_ARN"; deploy_arn="$RESOLVED_DEPLOY_ARN"

  echo "==> project=$project state_bucket_name=$bucket"
  echo "    ci_plan_role_arn=$plan_arn"
  echo "    ci_deploy_role_arn=$deploy_arn"

  verify_aws_resources "$bucket" "$plan_arn" "$deploy_arn" "$account_id" "$project"

  if has_state; then
    echo
    echo "==> $BOOTSTRAP_DIR には既に local state があります。未インポート分だけ補います（再実行しても安全）。"
  elif ! $no_restore && try_restore_from_backup "$bucket"; then
    echo
    echo "==> S3バックアップからの復元で完了しました（terraform import は実行していません）。"
    return
  fi

  echo
  echo "==> 以下の値で terraform.auto.tfvars を書き、main.tf の各リソースを import します"
  echo "    （既に state にあるリソースはスキップします）:"
  echo "      project              = $project"
  echo "      github_org           = $org"
  echo "      github_repo          = $repo"
  echo "      state_bucket_name    = $bucket"
  echo "      aws_region           = $region"
  echo "      create_oidc_provider = $owns_oidc"
  if ! $owns_oidc && oidc_provider_exists; then
    echo
    echo "      注意: このAWSアカウントにはGitHub Actions OIDCプロバイダーが既に存在しますが、"
    echo "      所有権（このbootstrapが作ったのか、同一アカウントを共有する他リポジトリのbootstrapが"
    echo "      作ったのか）はAWS側からは判別できないため、既定では import しません（データソースとして"
    echo "      参照するだけ）。このbootstrapが作成したと確信できる場合のみ --owns-oidc-provider を"
    echo "      指定してください（誤って指定すると、他リポジトリが使っているOIDCプロバイダーをこの"
    echo "      state が『所有』したことになり、将来の '$0 destroy --include-oidc-provider' で"
    echo "      誤削除するリスクがあります）。"
  fi
  echo

  confirm "$yes" "続行しますか？（terraform init と複数の terraform import を実行します）" || { echo "中止しました。"; exit 1; }

  local plan_role_name="${plan_arn##*/}" deploy_role_name="${deploy_arn##*/}"
  # main.tf の local.name_prefix（"${project}-${resource_name_suffix}"）と同じ規則で決定的な
  # ので、plan_role_name（"<project>-<suffix>-ci-plan"）から逆算する
  # （verify_aws_resourcesと同じロジック、suffixはrandom6で常に6文字固定）。
  local plan_name_without_role="${plan_role_name%-ci-plan}"
  local suffix="${plan_name_without_role: -6}"

  write_tfvars "$project" "$org" "$repo" "$bucket" "$region" "$owns_oidc" "$suffix"
  tf init

  local ro_policy_arn="arn:aws:iam::aws:policy/ReadOnlyAccess"

  # ci_deploy_* リソースのアドレス suffix → main.tf のポリシー名 suffix
  # （aws_iam_policy.<key> の name = "${project}-<suffix>"）。main.tf の
  # 該当 resource ブロックにポリシーを追加/変更したら、ここも合わせて更新すること。
  declare -A policy_suffix=(
    [ci_deploy_state]="deploy-tfstate-access"
    [ci_deploy_network]="deploy-network"
    [ci_deploy_compute]="deploy-compute"
    [ci_deploy_storage_cdn]="deploy-storage-cdn"
    [ci_deploy_data]="deploy-data"
    [ci_deploy_auth]="deploy-auth"
    [ci_deploy_observability]="deploy-observability"
    [ci_deploy_iam]="manage-project-iam"
  )

  # main.tf の全 managed resource（data source は除く）の address / import ID 対応表を組み立てる。
  local addresses=() ids=()

  addresses+=("aws_s3_bucket.state"); ids+=("$bucket")
  addresses+=("aws_s3_bucket_versioning.state"); ids+=("$bucket")
  addresses+=("aws_s3_bucket_server_side_encryption_configuration.state"); ids+=("$bucket")
  addresses+=("aws_s3_bucket_public_access_block.state"); ids+=("$bucket")
  addresses+=("aws_s3_bucket_lifecycle_configuration.state"); ids+=("$bucket")
  addresses+=("aws_s3_bucket_policy.state"); ids+=("$bucket")

  if $owns_oidc; then
    addresses+=("aws_iam_openid_connect_provider.github[0]")
    ids+=("arn:aws:iam::${account_id}:oidc-provider/token.actions.githubusercontent.com")
  fi

  addresses+=("aws_iam_role.ci_plan"); ids+=("$plan_role_name")
  addresses+=("aws_iam_role_policy_attachment.ci_plan_readonly"); ids+=("${plan_role_name}/${ro_policy_arn}")
  addresses+=("aws_iam_role_policy.ci_plan_access_analyzer"); ids+=("${plan_role_name}:access-analyzer-validate-policy")
  addresses+=("aws_iam_role_policy.ci_plan_state"); ids+=("${plan_role_name}:tfstate-access-dev")

  addresses+=("aws_iam_role.ci_deploy"); ids+=("$deploy_role_name")

  # agent_mcp（#571）: ARNをリポジトリ変数から読まず、project + suffixから決定的に名前を
  # 組み立てる（verify_aws_resourcesの存在確認と同じロジック）。信頼ポリシーはaccount root
  # principalなので、CI用ロールと違いOIDCプロバイダーとは無関係。
  local agent_mcp_role_name="${project}-${suffix}-agent-mcp"
  addresses+=("aws_iam_role.agent_mcp"); ids+=("$agent_mcp_role_name")
  addresses+=("aws_iam_role_policy_attachment.agent_mcp_readonly"); ids+=("${agent_mcp_role_name}/${ro_policy_arn}")
  addresses+=("aws_iam_role_policy.agent_mcp_guardrails"); ids+=("${agent_mcp_role_name}:mcp-guardrails")

  local key policy_arn
  for key in ci_deploy_state ci_deploy_network ci_deploy_compute ci_deploy_storage_cdn \
    ci_deploy_data ci_deploy_auth ci_deploy_observability ci_deploy_iam; do
    policy_arn="arn:aws:iam::${account_id}:policy/${project}-${suffix}-${policy_suffix[$key]}"
    addresses+=("aws_iam_policy.${key}"); ids+=("$policy_arn")
    addresses+=("aws_iam_role_policy_attachment.${key}"); ids+=("${deploy_role_name}/${policy_arn}")
  done

  echo
  echo "==> terraform import を実行します（${#addresses[@]}件）..."
  local existing_state
  existing_state="$(tf state list 2>/dev/null || true)"

  local i addr id failed=() imported=0 skipped=0
  for i in "${!addresses[@]}"; do
    addr="${addresses[$i]}"
    id="${ids[$i]}"
    if grep -qxF "$addr" <<<"$existing_state"; then
      echo "  [skip] $addr（既に state にあります）"
      skipped=$((skipped + 1))
      continue
    fi
    if tf import "$addr" "$id" >/dev/null; then
      echo "  [ok]   $addr"
      imported=$((imported + 1))
    else
      echo "  [FAIL] $addr (id: $id)" >&2
      failed+=("$addr")
    fi
  done

  echo
  echo "==> import 完了: ${imported}件 新規 / ${skipped}件 スキップ済み / ${#failed[@]}件 失敗"

  if [[ ${#failed[@]} -gt 0 ]]; then
    echo
    echo "Error: 以下のリソースの import に失敗しました:" >&2
    printf '    - %s\n' "${failed[@]}" >&2
    echo "       main.tf の該当リソース定義とAWS側の実リソースを確認し、必要なら手動で" >&2
    echo "       'terraform -chdir=$BOOTSTRAP_DIR import <address> <id>' を実行するか、" >&2
    echo "       '$0 recover' を再実行してください（成功済み分はスキップされます）。" >&2
    exit 1
  fi

  backup_state

  echo
  echo "==> 完了。次のコマンドで差分が無いことを確認してください"
  echo "    （差分がある場合、import ID の想定と main.tf の実際の定義がずれている可能性があります）:"
  echo "      terraform -chdir=$BOOTSTRAP_DIR plan"
  echo "    差分が無ければ、このマシンで '$0 update' / '$0 write' / '$0 destroy' が使えます。"
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

  echo "==> state バケット・OIDCプロバイダー以外（ci_plan/ci_deploy/agent_mcpロールとそのポリシー）を破棄します。"
  confirm "$yes" "続行しますか？" || { echo "中止しました。"; exit 1; }

  local targets=(
    aws_iam_role_policy.agent_mcp_guardrails
    aws_iam_role_policy_attachment.agent_mcp_readonly
    aws_iam_role.agent_mcp
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
    adopt) cmd_adopt "$@" ;;
    recover) cmd_recover "$@" ;;
    -h | --help | "") usage; [[ -z "$command" ]] && exit 2 || exit 0 ;;
    *) echo "Error: unknown command: $command" >&2; usage; exit 2 ;;
  esac
}

main "$@"
