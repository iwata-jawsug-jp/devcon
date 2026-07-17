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
if grep -rl -e 'devcon' -e 'itouhi' -e 'ap-northeast-1' "$GEN" --exclude-dir=.git; then
  echo "[scaffold-verify] NG: 未置換の文字列が上記ファイルに残っています" >&2
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
