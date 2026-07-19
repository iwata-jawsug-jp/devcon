#!/usr/bin/env bash
#
# AWS SSO 初期設定スクリプト
#
# サブコマンド:
#   login (既定、省略可)  - 1. ~/.aws/config に SSO プロファイルを書き込む
#                                （aws configure set で既存設定を壊さない）
#                            2. aws sso login で認証する
#                            3. aws sts get-caller-identity で認証できたか確認する
#                            sso_account_id と SSO start URL は必須オプション引数
#                            （環境固有のため既定値を持たない）。他の値はデフォルトを
#                            持ち、必要ならオプションで上書きできる。
#   agent-mcp              - infra/bootstrap が作る agent-mcp ロール（#571、AWS MCP
#                            Server用）を、既にログイン済みのSSOプロファイル経由で
#                            assume-roleするプロファイルを ~/.aws/config に追加する
#                            （docs/aws-temporary-credentials.md §5 の手順を自動化、
#                            #572）。プロファイル名は "agent-mcp" 固定
#                            （.mcp.json の aws エントリがこの名前をハードコードして
#                            参照しているため、変更すると .mcp.json 側も直す必要がある）。
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP_DIR="$REPO_ROOT/infra/bootstrap"
AGENT_MCP_PROFILE="agent-mcp"

usage() {
  cat <<'EOF'
Usage: aws-sso-setup.sh [login] -a <sso_account_id> -u <start_url> [options]
       aws-sso-setup.sh agent-mcp [options]

Commands:
  login       (default, name can be omitted) Set up an SSO profile, log in, and verify.
                -a, --account-id <id>      AWS account ID (sso_account_id, 12 digits) [required]
                -u, --start-url <url>      SSO start URL, e.g. https://<portal>.awsapps.com/start [required]
                -p, --profile <name>       Profile name                  (default: default)
                -r, --sso-region <region>  SSO region                    (default: ap-northeast-1)
                -n, --role-name <name>     SSO permission set / role name (default: AWSAdministratorAccess)
                -R, --region <region>      Default region                (default: ap-northeast-1)
                -o, --output <format>      Output format                 (default: json)

  agent-mcp   Add an assume-role profile ("agent-mcp", fixed name) for the AWS MCP Server's
              agent-only IAM role (#571), sourced from an already-logged-in SSO profile
              (docs/aws-temporary-credentials.md §5). Requires either a local
              infra/bootstrap Terraform state (role ARN auto-detected via `terraform
              output`) or an explicit --role-arn.
                -p, --sso-profile <name>   SSO profile to assume-role from (default: default)
                --role-arn <arn>           agent-mcp role ARN (default: auto-detected via
                                            `terraform -chdir=infra/bootstrap output -raw
                                            agent_mcp_role_arn`)
                -R, --region <region>      Default region                (default: ap-northeast-1)
                --duration-seconds <n>     Assumed session duration       (default: 3600)

  -h, --help  Show this help

Examples:
  ./tools/script/aws-sso-setup.sh -a <sso_account_id> -u <start_url>
  ./tools/script/aws-sso-setup.sh agent-mcp
  ./tools/script/aws-sso-setup.sh agent-mcp --sso-profile dev --role-arn arn:aws:iam::123456789012:role/devcon-ab12cd-agent-mcp
EOF
}

# ============================================================
# login（既定）
# ============================================================
cmd_login() {
  local profile="default" start_url="" sso_region="ap-northeast-1"
  local role_name="AWSAdministratorAccess" region="ap-northeast-1" output="json" account_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--account-id) account_id="${2:-}"; shift 2 ;;
      -p|--profile)    profile="${2:-}";    shift 2 ;;
      -u|--start-url)  start_url="${2:-}";  shift 2 ;;
      -r|--sso-region) sso_region="${2:-}"; shift 2 ;;
      -n|--role-name)  role_name="${2:-}";  shift 2 ;;
      -R|--region)     region="${2:-}";     shift 2 ;;
      -o|--output)     output="${2:-}";     shift 2 ;;
      -h|--help)       usage; exit 0 ;;
      *) echo "Error: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
  done

  if [[ -z "$account_id" ]]; then
    echo "Error: --account-id (sso_account_id) is required." >&2
    usage
    exit 2
  fi
  if ! [[ "$account_id" =~ ^[0-9]{12}$ ]]; then
    echo "Error: account-id must be 12 digits: '$account_id'" >&2
    exit 2
  fi
  if [[ -z "$start_url" ]]; then
    echo "Error: --start-url (SSO start URL) is required." >&2
    usage
    exit 2
  fi

  command -v aws >/dev/null 2>&1 || { echo "Error: aws CLI not found." >&2; exit 1; }

  echo "==> Writing profile '$profile' to ~/.aws/config"
  aws configure set sso_start_url   "$start_url"  --profile "$profile"
  aws configure set sso_region      "$sso_region" --profile "$profile"
  aws configure set sso_account_id  "$account_id" --profile "$profile"
  aws configure set sso_role_name   "$role_name"  --profile "$profile"
  aws configure set region          "$region"     --profile "$profile"
  aws configure set output          "$output"     --profile "$profile"

  echo "==> aws sso login --profile $profile"
  aws sso login --profile "$profile"

  echo "==> aws sts get-caller-identity --profile $profile"
  if aws sts get-caller-identity --profile "$profile"; then
    echo "==> Success: SSO authentication verified for profile '$profile'."
  else
    echo "Error: get-caller-identity failed. Authentication may not be complete." >&2
    exit 1
  fi
}

# ============================================================
# agent-mcp
# ============================================================
cmd_agent_mcp() {
  local sso_profile="default" role_arn="" region="ap-northeast-1" duration=3600

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--sso-profile)     sso_profile="${2:-}"; shift 2 ;;
      --role-arn)           role_arn="${2:-}";    shift 2 ;;
      -R|--region)          region="${2:-}";      shift 2 ;;
      --duration-seconds)   duration="${2:-}";    shift 2 ;;
      -h|--help)             usage; exit 0 ;;
      *) echo "Error: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
  done

  command -v aws >/dev/null 2>&1 || { echo "Error: aws CLI not found." >&2; exit 1; }

  echo "==> SSOプロファイル '$sso_profile' の認証状態を確認します..."
  if ! aws sts get-caller-identity --profile "$sso_profile" >/dev/null 2>&1; then
    echo "==> セッションが無いか期限切れのため、aws sso login --profile $sso_profile を実行します"
    aws sso login --profile "$sso_profile"
  fi
  local sso_caller
  sso_caller="$(aws sts get-caller-identity --profile "$sso_profile" --query Arn --output text)"
  echo "==> SSOプロファイル '$sso_profile' で認証済み: $sso_caller"

  if [[ -z "$role_arn" ]]; then
    echo "==> --role-arn 未指定のため、infra/bootstrap の terraform output から自動検出します..."
    if ! role_arn="$(terraform -chdir="$BOOTSTRAP_DIR" output -raw agent_mcp_role_arn 2>/dev/null)" || [[ -z "$role_arn" ]]; then
      echo "Error: agent_mcp_role_arn を自動検出できませんでした。" >&2
      echo "       このマシンに infra/bootstrap のローカルstateが無い場合（例: 'adopt' で" >&2
      echo "       別マシンの設定を取り込んだだけの環境）は --role-arn で明示指定してください。" >&2
      exit 1
    fi
  fi
  echo "==> agent-mcp ロール: $role_arn"

  echo "==> プロファイル '$AGENT_MCP_PROFILE' を ~/.aws/config に書き込みます"
  echo "    （source_profile=$sso_profile 経由で assume-role。プロファイル名は .mcp.json の"
  echo "    aws エントリがハードコードして参照するため固定）"
  aws configure set role_arn         "$role_arn"    --profile "$AGENT_MCP_PROFILE"
  aws configure set source_profile   "$sso_profile" --profile "$AGENT_MCP_PROFILE"
  aws configure set region           "$region"      --profile "$AGENT_MCP_PROFILE"
  aws configure set duration_seconds "$duration"     --profile "$AGENT_MCP_PROFILE"

  echo "==> aws sts get-caller-identity --profile $AGENT_MCP_PROFILE"
  if aws sts get-caller-identity --profile "$AGENT_MCP_PROFILE"; then
    echo "==> Success: '$AGENT_MCP_PROFILE' プロファイルで agent-mcp ロールを引き受けられます。"
    echo "    （このロールは DenyUnlessViaAWSMCP により、素の AWS CLI/SDK 呼び出しは"
    echo "    get-caller-identity 等 STS 以外すべて意図的に拒否されます。実際の権限確認は"
    echo "    Claude Code 再起動後、AWS MCP Server 経由のツール呼び出しで行ってください。）"
  else
    echo "Error: get-caller-identity に失敗しました。" >&2
    echo "       SSOプロファイル '$sso_profile' のpermission setに、このロールARNへの" >&2
    echo "       sts:AssumeRole 権限が無い可能性があります（docs/aws-temporary-credentials.md" >&2
    echo "       §5参照）。AWSAdministratorAccess相当なら通常は追加権限不要です。" >&2
    exit 1
  fi
}

# ============================================================
main() {
  case "${1:-}" in
    agent-mcp) shift; cmd_agent_mcp "$@" ;;
    login)     shift; cmd_login "$@" ;;
    -h|--help) usage; exit 0 ;;
    *)         cmd_login "$@" ;;
  esac
}

main "$@"
