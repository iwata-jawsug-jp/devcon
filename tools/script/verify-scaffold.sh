#!/usr/bin/env bash
# copier.yml から実際にプロジェクトを生成し、生成物が壊れていないことを検証する。
# #294「生成物の検証CI」。ローカル: make scaffold-verify / CI: ci.yml の scaffold ジョブ。
#
# スコープ: テンプレート化の機構（除外リスト・sed置換）が壊れていないことの確認に絞る。
# backend の DB 統合テスト・frontend の E2E・infra のセキュリティスキャンは、生成物固有の
# リスクではなく既存の backend/frontend/infra ジョブが常時カバーしているため、ここでは
# 重複実行しない（生成物にだけ起こり得る問題 = 文字列置換による構文破壊・構成崩れに絞る）。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
GEN="$WORK/generated"

TEST_PROJECT_NAME="${TEST_PROJECT_NAME:-scaffold-verify}"
TEST_GITHUB_ORG="${TEST_GITHUB_ORG:-example-org}"
TEST_AWS_REGION="${TEST_AWS_REGION:-us-east-1}"

echo "[scaffold-verify] copier copy (project_name=$TEST_PROJECT_NAME) ..."
copier copy \
  --vcs-ref=HEAD \
  --data "project_name=$TEST_PROJECT_NAME" \
  --data "github_org=$TEST_GITHUB_ORG" \
  --data "github_repo=$TEST_PROJECT_NAME" \
  --data "aws_region=$TEST_AWS_REGION" \
  --defaults --trust \
  "$REPO_ROOT" "$GEN"

echo "[scaffold-verify] 置換漏れチェック（devcon / itouhi / ap-northeast-1 の残存禁止）"
# devcon だけ \b で単語境界を要求する: publish-to-public.sh はこのスクリプト自身も
# 含めて devcon → devcon を無差別に文字列置換するため、公開ミラー
# （iwata-jawsug-jp/devcon）側では実行時にこの行の 'devcon' も 'devcon' に化ける。
# 単語境界なしだと devcontainer という頻出語の先頭一致を「残存あり」と誤検知する
# （copier.yml の _tasks が同じ理由で \bdevcon\b にしているのと同じ罠・同じ対策。
# #517/#536 で実機確認）。itouhi / ap-northeast-1 は衝突が無く、単語境界を付けると
# Cognito ユーザープールID形式（末尾がアンダースコア）の正当な残存を見逃すため付けない。
# .copier-answers.yml は除外する: _src_path は copier update が参照する本物のテンプレート
# 配布元（devcon/itouhi を含む）を意図的に保持している（下記の専用チェック参照）。
if grep -rlP '\bdevcon\b' "$GEN" --exclude-dir=.git --exclude=.copier-answers.yml \
  || grep -rl -e 'itouhi' -e 'ap-northeast-1' "$GEN" --exclude-dir=.git --exclude=.copier-answers.yml; then
  echo "[scaffold-verify] NG: 未置換の文字列が上記ファイルに残っています" >&2
  exit 1
fi
echo "[scaffold-verify] OK"

echo "[scaffold-verify] .copier-answers.yml（copier update の前提）の整合性チェック"
# .copier-answers.yml は .copier-answers.yml.jinja から copier が自動生成する。存在しないと
# `copier update` が「テンプレート参照を取得できない」で即エラーになり、下流リポジトリの
# 追従（#298）が原理的に不可能になる（実機確認済み）。_src_path は copier.yml の _tasks による
# 文字列置換の対象外にしてある（除外しないと devcon/itouhi を含む本物のテンプレート
# 配布元が書き換わってしまう）ため、生成元パスと完全一致するはずのものを検証する。
ANSWERS_FILE="$GEN/.copier-answers.yml"
if [[ ! -f "$ANSWERS_FILE" ]]; then
  echo "[scaffold-verify] NG: .copier-answers.yml が生成されていません（.copier-answers.yml.jinja を確認）" >&2
  exit 1
fi
if ! grep -qF "_src_path: $REPO_ROOT" "$ANSWERS_FILE"; then
  echo "[scaffold-verify] NG: .copier-answers.yml の _src_path が生成元パスと一致しません（sed置換で書き換わった疑い）" >&2
  cat "$ANSWERS_FILE" >&2
  exit 1
fi
if ! grep -qF "project_name: $TEST_PROJECT_NAME" "$ANSWERS_FILE"; then
  echo "[scaffold-verify] NG: .copier-answers.yml に project_name が正しく記録されていません" >&2
  exit 1
fi
echo "[scaffold-verify] OK"

echo "[scaffold-verify] 混入チェック（.git / copier.yml / copier.yaml が生成物に含まれないこと）"
for leaked in .git copier.yml copier.yaml; do
  if [[ -e "$GEN/$leaked" ]]; then
    echo "[scaffold-verify] NG: 生成物に $leaked が混入しています（copier.yml の _exclude を確認）" >&2
    exit 1
  fi
done
echo "[scaffold-verify] OK"

echo "[scaffold-verify] copier update の往復チェック（#298: 追従経路そのものが機能することの回帰防止）"
# $GEN 自体は後続チェック（.git 混入チェック含む）が使い続けるため、往復チェックだけは
# 別ディレクトリにコピーしてそこで git init する。生成直後の状態から自分自身へ
# copier update をかけ、エラーなく完走することだけを確認する（差分ゼロの往復）。
# .copier-answers.yml が壊れている/存在しないケースはこの往復が即エラーになるため、
# 実際のテンプレートドリフトを用意しなくても退行を検知できる。
#
# --vcs-ref=HEAD を明示する: 無指定だと copier は「最新の git tag」をデフォルトの更新先に
# する（セマンティックバージョンタグ運用が前提の設計）。本リポジトリはリリースの度に
# vX.Y.Z タグを打つ運用（docs/release.md）のため、タグ後に1つでもコミットが進むと
# 「現在地（タグ+N commits、PEP440的には新しい）」から「最新タグ（タグそのもの、
# PEP440的には古い）」への更新は copier に "downgrade" と判定され拒否される
# （実機確認済み、#298）。ここでは HEAD 自身への往復を確認したいだけなので明示する。
GEN_UPDATE="$WORK/generated-update-check"
cp -r "$GEN" "$GEN_UPDATE"
(
  cd "$GEN_UPDATE"
  git init -q
  git -c user.email=scaffold-verify@example.invalid -c user.name=scaffold-verify add -A
  git -c user.email=scaffold-verify@example.invalid -c user.name=scaffold-verify commit -q -m "scaffold-verify: initial generation"
  copier update --trust --defaults --vcs-ref=HEAD
)
echo "[scaffold-verify] OK"

echo "[scaffold-verify] terraform fmt/validate (infra, infra/bootstrap) ..."
for layer in infra infra/bootstrap; do
  (
    cd "$GEN/$layer"
    terraform fmt -check -recursive
    terraform init -backend=false -input=false >/dev/null
    terraform validate
  )
done
echo "[scaffold-verify] OK"

echo "[scaffold-verify] backend: uv sync + ruff + mypy ..."
(
  cd "$GEN/services/backend/python"
  uv sync --all-extras --dev --quiet
  uv run ruff check .
  uv run mypy .
)
echo "[scaffold-verify] OK"

echo "[scaffold-verify] frontend: npm ci + lint + type-check + unit test ..."
(
  cd "$GEN/services/frontend"
  npm ci --silent
  npm run lint
  npx vue-tsc --noEmit
  npm test
)
echo "[scaffold-verify] OK"

echo "[scaffold-verify] JSON構文チェック（devcontainer.json / package.json / tsconfig*.json）..."
python3 - "$GEN" <<'PYEOF'
import json
import re
import sys
from pathlib import Path

gen = Path(sys.argv[1])

# devcontainer.json / tsconfig*.json は JSONC（// および /* */ コメント、
# 末尾カンマを許容）なので、strict JSON としてパースする前に取り除く。
# 文字列リテラル中の "//"（例: "ghcr.io/devcontainers/..."）をコメントと
# 誤認しないよう、文字列の内外を追跡しながら1文字ずつ走査する。
def strip_jsonc(text):
    out = []
    in_string = False
    escape = False
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == '\\':
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
        elif ch == '/' and i + 1 < n and text[i + 1] == '/':
            i = text.find('\n', i)
            if i == -1:
                i = n
        elif ch == '/' and i + 1 < n and text[i + 1] == '*':
            end = text.find('*/', i + 2)
            i = n if end == -1 else end + 2
        else:
            out.append(ch)
            i += 1
    text = ''.join(out)
    text = re.sub(r',(\s*[}\]])', r'\1', text)
    return text

jsonc_targets = [gen / ".devcontainer/devcontainer.json"]
jsonc_targets += sorted((gen / "services/frontend").glob("tsconfig*.json"))
strict_targets = [gen / "services/frontend/package.json"]

for p in jsonc_targets:
    json.loads(strip_jsonc(p.read_text()))
for p in strict_targets:
    json.loads(p.read_text())

total = len(jsonc_targets) + len(strict_targets)
print(f"[scaffold-verify] OK ({total} files)")
PYEOF

echo "[scaffold-verify] 全チェック green"
