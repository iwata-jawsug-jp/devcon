#!/usr/bin/env bash
#
# AWS SSO 初期設定スクリプト
#
#   1. ~/.aws/config に SSO プロファイルを書き込む（aws configure set で既存設定を壊さない）
#   2. aws sso login で認証する
#   3. aws sts get-caller-identity で認証できたか確認する
#
# sso_account_id と SSO start URL は必須オプション引数（環境固有のため既定値を持たない）。
# その他の値はデフォルトを持ち、必要ならオプションで上書きできる。
#
set -euo pipefail

# ---- デフォルト値 ----
PROFILE="default"
START_URL=""
SSO_REGION="ap-northeast-1"
ROLE_NAME="AWSAdministratorAccess"
REGION="ap-northeast-1"
OUTPUT="json"
ACCOUNT_ID=""

usage() {
  cat <<'EOF'
Usage: aws-sso-setup.sh -a <sso_account_id> [options]

Required:
  -a, --account-id <id>      AWS アカウントID（sso_account_id, 12桁）
  -u, --start-url <url>      SSO start URL（例: https://<your-portal>.awsapps.com/start）

Options:
  -p, --profile <name>       プロファイル名            (default: default)
  -r, --sso-region <region>  SSO リージョン            (default: ap-northeast-1)
  -n, --role-name <name>     SSO ロール名              (default: AWSAdministratorAccess)
  -R, --region <region>      デフォルトリージョン      (default: ap-northeast-1)
  -o, --output <format>      出力形式                  (default: json)
  -h, --help                 このヘルプを表示

Example:
  ./tools/script/aws-sso-setup.sh -a <sso_account_id> -u <start_url>
EOF
}

# ---- 引数パース ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--account-id) ACCOUNT_ID="${2:-}"; shift 2 ;;
    -p|--profile)    PROFILE="${2:-}";    shift 2 ;;
    -u|--start-url)  START_URL="${2:-}";  shift 2 ;;
    -r|--sso-region) SSO_REGION="${2:-}"; shift 2 ;;
    -n|--role-name)  ROLE_NAME="${2:-}";  shift 2 ;;
    -R|--region)     REGION="${2:-}";     shift 2 ;;
    -o|--output)     OUTPUT="${2:-}";     shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Error: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# ---- 必須チェック ----
if [[ -z "$ACCOUNT_ID" ]]; then
  echo "Error: --account-id (sso_account_id) is required." >&2
  usage
  exit 2
fi
if ! [[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  echo "Error: account-id must be 12 digits: '$ACCOUNT_ID'" >&2
  exit 2
fi
if [[ -z "$START_URL" ]]; then
  echo "Error: --start-url (SSO start URL) is required." >&2
  usage
  exit 2
fi

command -v aws >/dev/null 2>&1 || { echo "Error: aws CLI not found." >&2; exit 1; }

# ---- 1. プロファイル書き込み ----
echo "==> Writing profile '$PROFILE' to ~/.aws/config"
aws configure set sso_start_url   "$START_URL"  --profile "$PROFILE"
aws configure set sso_region      "$SSO_REGION" --profile "$PROFILE"
aws configure set sso_account_id  "$ACCOUNT_ID" --profile "$PROFILE"
aws configure set sso_role_name   "$ROLE_NAME"  --profile "$PROFILE"
aws configure set region          "$REGION"     --profile "$PROFILE"
aws configure set output          "$OUTPUT"     --profile "$PROFILE"

# ---- 2. SSO ログイン ----
echo "==> aws sso login --profile $PROFILE"
aws sso login --profile "$PROFILE"

# ---- 3. 認証確認 ----
echo "==> aws sts get-caller-identity --profile $PROFILE"
if aws sts get-caller-identity --profile "$PROFILE"; then
  echo "==> Success: SSO authentication verified for profile '$PROFILE'."
else
  echo "Error: get-caller-identity failed. Authentication may not be complete." >&2
  exit 1
fi
