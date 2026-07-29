#!/usr/bin/env bash
#
# GitHub のデフォルトブランチ名を変更する（任意の旧名 -> 新名に対応する汎用ツール。
# scaffold-cli（#294）が生成する新規プロジェクト等でも使い回せる）。
#
# 2段階に分かれている（デフォルトは1のみ。2は明示的なフラグが無いと実行しない）:
#
#   1. sync-workflows（既定の動作）
#      .github/workflows/*.yml 内の、トリガーとして解釈される旧ブランチ名の参照
#      （`branches: [<old>]` 等）を新ブランチ名に書き換える。ワーキングツリーの
#      編集のみ — コミットや push はしない（このリポジトリの main は org-baseline
#      ルールセットで直push禁止・PR必須のため、通常のPRフローでレビュー・マージする
#      こと）。安全・可逆な変更なのでこれ単体では確認プロンプトを出さない。
#
#   2. rename（--rename を付けたときのみ）
#      `gh api -X POST repos/<org>/<repo>/branches/<old>/rename` で実際に GitHub 上の
#      ブランチ名を変更する。これは破壊的で後戻りしにくい操作（default_branch の
#      向き先が変わる・進行中のPRのbaseが自動で付け替わる・旧名は一定期間の
#      リダイレクトのみで恒久的ではない・ローカルクローン全員が追従作業を要する）
#      なので、1で workflow ファイルの変更を先にPRマージしてから実行することを
#      強く推奨する（このスクリプトは自動でPRを作らない — 順序はユーザーが判断する）。
#
# 対象は .github/workflows/ 配下の「トリガーとして解釈される」参照のみ
# （`branches:` / `branches-ignore:` のリスト、コメントではない実コード）。
# docs/ や README 等の文章中の言及、Terraform 側（infra/bootstrap/locals.tf の
# OIDC trust policy 等）は対象外 — 別途手動で確認すること。
#
# Usage:
#   ./tools/script/rename-default-branch.sh <old> <new> [--rename] [-o org] [-r repo] [--dry-run] [-y]
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

usage() {
  cat <<'EOF'
Usage: rename-default-branch.sh <old> <new> [options]

GitHub のデフォルトブランチ名を <old> から <new> に変更する。

  1. .github/workflows/*.yml 内のトリガー参照（branches: [<old>] 等）を書き換える
     （ワーキングツリー編集のみ。コミット/pushはしない。既定の動作）。
  2. --rename を付けた場合のみ、GitHub 上のブランチ名自体を実際にリネームする
     （default_branch の付け替えを含む、破壊的・後戻りしにくい操作）。

  1 のPRをマージしてから 2 を実行することを推奨する（順序はユーザー判断・
  このスクリプトは強制しない）。

Arguments:
  <old>   現在のデフォルトブランチ名（例: main）
  <new>   変更後のブランチ名

Options:
  --rename            GitHub 上のブランチを実際にリネームする（既定では workflow
                       ファイルの書き換えのみで、この操作は行わない）
  -o, --org <org>      GitHub org（省略時は自動検出）
  -r, --repo <repo>    GitHub repo（省略時は自動検出）
  --dry-run            変更内容を表示するだけで、ファイル書き換え・GitHub操作を行わない
  -y, --yes             --rename 実行時の確認プロンプトをスキップ
  -h, --help            このヘルプを表示

前提:
  - gh でログイン済みであること。--rename には対象リポジトリの admin 権限が必要。
EOF
}

old=""
new=""
org=""
repo=""
do_rename=false
dry_run=false
yes=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rename) do_rename=true; shift ;;
    -o | --org) org="${2:-}"; shift 2 ;;
    -r | --repo) repo="${2:-}"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -y | --yes) yes=true; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) echo "Error: unknown option: $1" >&2; usage; exit 2 ;;
    *)
      if [[ -z "$old" ]]; then old="$1";
      elif [[ -z "$new" ]]; then new="$1";
      else echo "Error: too many arguments: $1" >&2; usage; exit 2; fi
      shift
      ;;
  esac
done

if [[ -z "$old" || -z "$new" ]]; then
  echo "Error: <old> <new> を指定してください。" >&2
  usage
  exit 2
fi
if [[ "$old" == "$new" ]]; then
  echo "Error: <old> と <new> が同じです。" >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh 未ログインです。gh auth login を実行してください。" >&2
  exit 1
fi

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
echo "==> ブランチ名変更: '$old' -> '$new'"

# sed 用にリテラルとしてエスケープ（正規表現・置換文字列の両方）
sed_escape_pattern() { printf '%s' "$1" | sed -e 's/[.[\*^$/\\]/\\&/g'; }
sed_escape_repl() { printf '%s' "$1" | sed -e 's/[&/\\]/\\&/g'; }
old_pat="$(sed_escape_pattern "$old")"
new_repl="$(sed_escape_repl "$new")"

# ---- 1. .github/workflows/*.yml のトリガー参照を書き換える ----
# 対象は「トリガーとして解釈される行」に限定する。branches:/branches-ignore: の
# 配列・リスト表記のみを対象にし、コメントや文章中の言及（例: issue タイトルの
# 文言、metrics-*.yml の「not main directly」という注記）は対象外とする
# （素の \bold\b 全置換だと "domain"/"main.tf" 等の無関係な文字列を巻き込む恐れがある）。
echo
echo "==> [1/2] .github/workflows/*.yml のトリガー参照を確認します..."
changed_files=()
other_mentions=()

shopt -s nullglob
for f in .github/workflows/*.yml; do
  # トリガー行: branches:/branches-ignore: を含む行のうち、旧ブランチ名を
  # 単語境界つきで含むもの
  trigger_lines="$(grep -nE "branches(-ignore)?:" "$f" | grep -E "\\b${old_pat}\\b" || true)"
  if [[ -n "$trigger_lines" ]]; then
    echo "  [$f]"
    echo "$trigger_lines" | sed 's/^/    /'
    if ! $dry_run; then
      sed -i -E "/branches(-ignore)?:/ s/\\b${old_pat}\\b/${new_repl}/g" "$f"
    fi
    changed_files+=("$f")
  fi

  # 上記トリガー行以外で旧ブランチ名を単語境界つきで含む行 -> 自動書き換えはせず、
  # 手動確認のためにリストアップするだけ
  other_lines="$(grep -nE "\\b${old_pat}\\b" "$f" | grep -vE "branches(-ignore)?:" || true)"
  if [[ -n "$other_lines" ]]; then
    other_mentions+=("--- $f ---"$'\n'"$other_lines")
  fi
done
shopt -u nullglob

if [[ ${#changed_files[@]} -eq 0 ]]; then
  echo "  トリガー参照は見つかりませんでした。"
elif $dry_run; then
  echo "  --dry-run のため書き換えていません（上記が変更予定箇所）。"
else
  echo "  ==> ${#changed_files[@]}ファイルを書き換えました（コミット/pushはしていません）。"
  echo "      git diff .github/workflows/ で確認のうえ、通常のPRフローでレビュー・マージしてください"
  echo "      （このリポジトリの main は org-baseline ルールセットで直push禁止・PR必須）。"
fi

if [[ ${#other_mentions[@]} -gt 0 ]]; then
  echo
  echo "  [手動確認推奨] トリガー行以外で '$old' への言及が見つかりました（自動書き換え対象外）:"
  printf '%s\n' "${other_mentions[@]}" | sed 's/^/    /'
fi

if [[ "$do_rename" != true ]]; then
  echo
  echo "==> --rename が指定されていないため、GitHub 上のブランチリネームは行いません。"
  exit 0
fi

# ---- 2. GitHub 上のブランチを実際にリネームする ----
echo
echo "==> [2/2] GitHub 上のブランチをリネームします。"

current_default="$(gh api "repos/$repo_slug" --jq '.default_branch')"
if [[ "$current_default" != "$old" ]]; then
  echo "  [警告] 現在のデフォルトブランチは '$current_default' で、指定した旧名 '$old' と一致しません。" >&2
fi

if ! gh api "repos/$repo_slug/branches/$old" >/dev/null 2>&1; then
  echo "Error: ブランチ '$old' が見つかりません。" >&2
  exit 1
fi
if gh api "repos/$repo_slug/branches/$new" >/dev/null 2>&1; then
  echo "Error: ブランチ '$new' は既に存在します。" >&2
  exit 1
fi

echo "  現在のデフォルトブランチ: $current_default"
echo "  この操作を行うと:"
echo "    - '$old' ブランチが '$new' にリネームされ、default_branch も '$new' に自動で変わる"
echo "    - '$old' を base/head にしていた進行中のPRは自動で '$new' に付け替わる"
echo "    - '$old' への push は一定期間 '$new' へリダイレクトされるが、恒久的ではない"
echo "    - ローカルクローンを持つ全員が追従作業（下記）を行う必要がある"

if $dry_run; then
  echo "  --dry-run のため実行しません。"
  exit 0
fi

if ! $yes; then
  echo
  read -r -p "本当に '$old' を '$new' にリネームしますか？ [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || {
    echo "中止しました。"
    exit 1
  }
fi

gh api -X POST "repos/$repo_slug/branches/$old/rename" -f new_name="$new" >/dev/null
echo "==> リネームしました: '$old' -> '$new'（default_branch も自動更新されています）。"
echo
echo "==> ローカルクローンでの追従手順（このリポジトリ・他の共同作業者にも共有すること）:"
cat <<EOF
    git branch -m $old $new
    git fetch origin
    git branch -u origin/$new $new
    git remote set-head origin -a
EOF
