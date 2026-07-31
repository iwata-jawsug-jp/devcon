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

# copier copy はローカルパスを直接ソースにする場合、git ではなく作業ツリーのファイルシステムを
# そのまま読む（--vcs-ref=HEAD を指定していても）。未コミットの変更があると、copier がその
# "dirty" 状態から合成した擬似バージョン（例: v0.7.3-12-gXXXXXXX-dirty）を
# .copier-answers.yml に記録し、後段の `copier update` 往復チェックがそれを実在する ref として
# checkout しようとして失敗する（実機確認済み、#699〜#701）。CI は常にクリーンな checkout
# なので影響しないが、ローカルで `make scaffold-verify` を未コミット変更がある状態で実行すると
# この理由で失敗し得る（本スクリプト自体のバグではない）。一言警告するだけに留める
# （verify-tree-health.sh の同種の警告と同じ方針）。
if [[ -n "$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null)" ]]; then
  echo "[scaffold-verify] 警告: 未コミットの変更があります。copier update 往復チェックが" >&2
  echo "  「dirty な擬似バージョンを checkout できない」エラーで失敗する可能性があります" >&2
  echo "  （既知の環境要因。コミット後に再実行してください）。" >&2
fi

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
#
# LC_ALL=C で copier.yml の _tasks の sed 呼び出しとロケールを揃える: \b は UTF-8
# ロケールだと CJK を alnum 扱いして "devcon" の直後に空白なしで日本語が続く箇所の
# 判定に失敗する（実機検証で確認済み）。ここを C 以外のロケールのままにすると、置換が
# 同じ理由で効かなかった場合にこのチェック自身も同じ箇所を見逃し、CI が偽陽性の green を
# 返してしまう（sed 側と grep 側で判定がズレていては検証にならない）。
if LC_ALL=C grep -rlP '\bdevcon\b' "$GEN" --exclude-dir=.git --exclude=.copier-answers.yml \
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

echo "[scaffold-verify] scaffold 配管が生成先に残っていないことのチェック（課題A、#702）"
# ファイル単位で切れるもの（tools/template/audience.yml で generate:false）。
for leaked in \
  ".github/workflows/reusable-scaffold.yml" \
  "tools/script/verify-scaffold.sh" \
  "tools/script/strip-audience-blocks.sh" \
  "tools/script/clean-excluded-doc-references.sh" \
  "tools/script/check_adr_audience.py"; do
  if [[ -e "$GEN/$leaked" ]]; then
    echo "[scaffold-verify] NG: 生成物に $leaked が混入しています（audience.yml の generate:false を確認）" >&2
    exit 1
  fi
done
# ファイル単位では切れないもの（audience:no-generate マーカーで囲んで除去する）。
if grep -qE '^\s*scaffold:' "$GEN/.github/workflows/ci.yml" "$GEN/.github/workflows/ci-sandbox.yml" \
  "$GEN/.github/workflows/reusable-changes.yml" 2>/dev/null; then
  echo "[scaffold-verify] NG: 生成物の ci.yml/ci-sandbox.yml/reusable-changes.yml に scaffold ジョブ/フィルタが残っています（audience:no-generate マーカーを確認）" >&2
  exit 1
fi
if grep -q '^scaffold-verify:' "$GEN/Makefile" 2>/dev/null; then
  echo "[scaffold-verify] NG: 生成物の Makefile に scaffold-verify ターゲットが残っています（audience:no-generate マーカーを確認）" >&2
  exit 1
fi
echo "[scaffold-verify] OK"

echo "[scaffold-verify] 除外先ドキュメントへの参照が生成先に残っていないことのチェック（課題E、#703）"
# 個別ADR（docs/adr/*.md、generate:false）へのリンクが飾りを外されてプレーンテキスト化されて
# いること・.github/dependabot.yml（generate:false）へのリンクが CONTRIBUTING.md から消えて
# いることを、代表例としてチェックする（実装は tools/script/clean-excluded-doc-references.sh
# に共通化済み、ここはその効果の回帰検知）。
if grep -qE '\]\([^()]*docs/adr/00[0-9]+-' "$GEN/README.md" 2>/dev/null; then
  echo "[scaffold-verify] NG: 生成物の README.md に個別ADR（generate:false）への実リンクが残っています（tools/script/clean-excluded-doc-references.sh を確認）" >&2
  exit 1
fi

echo "[scaffold-verify] ADR個別のAudience分類が生成先に反映されていることのチェック（課題B主部、#704）"
# generate:false（publish のみ）な6本は生成物に存在してはいけない。tools/template/audience.yml
# の該当エントリを手で列挙しているため、追加・削除したらここも合わせて更新すること
# （make audience-drift-check の check_adr_audience.py が Audience 行との食い違いは検出するが、
# 生成物に実際に出ていないことまでは検証しないため、ここで別途確認する）。
for adr in \
  "0010-adopt-copier-for-scaffold-cli" \
  "0011-scaffold-template-in-place" \
  "0013-decline-aidlc-workflows-adoption" \
  "0016-terraform-bootstrap-module-distributed-in-repo" \
  "0019-policy-as-code-downstream-distribution" \
  "0028-template-and-generated-asset-separation"; do
  if [[ -e "$GEN/docs/adr/${adr}.md" ]]; then
    echo "[scaffold-verify] NG: 生成物に docs/adr/${adr}.md が混入しています（テンプレート運用の判断、generate:false のはず）" >&2
    exit 1
  fi
done
# generate:true な残りのADR（template.md含め23本）は逆に存在するはず。
if [[ ! -e "$GEN/docs/adr/0001-record-architecture-decisions.md" || ! -e "$GEN/docs/adr/template.md" ]]; then
  echo "[scaffold-verify] NG: 生成先にプロダクトADR（generate:true）が揃っていません" >&2
  exit 1
fi
if grep -qE '\]\([^()]*dependabot\.yml\)' "$GEN/CONTRIBUTING.md" 2>/dev/null; then
  echo "[scaffold-verify] NG: 生成物の CONTRIBUTING.md に .github/dependabot.yml（generate:false）への実リンクが残っています（課題E が再発しています）" >&2
  exit 1
fi
echo "[scaffold-verify] OK"

echo "[scaffold-verify] 生成物の GitHub Actions workflow YAML 構文チェック（audience:no-* マーカー除去による破損検知）"
python3 - "$GEN/.github/workflows" <<'PYEOF'
import sys
from pathlib import Path
import yaml

wf_dir = Path(sys.argv[1])
for p in sorted(wf_dir.glob("*.yml")) + sorted(wf_dir.glob("*.yaml")):
    try:
        yaml.safe_load(p.read_text())
    except yaml.YAMLError as e:
        print(f"[scaffold-verify] NG: {p} が不正なYAMLです: {e}", file=sys.stderr)
        sys.exit(1)
print(f"[scaffold-verify] OK ({len(list(wf_dir.glob('*.y*ml')))} files)")
PYEOF

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
#
# 注意（#701 独立検証で判明）: この HEAD→HEAD（ドリフト無し）往復は「update コマンドが
# エラーなく完走すること」しか保証しない。copier update は内部で3-way merge を行い、
# テンプレート側に実際の差分が無い場合は生成済みの内容を「ローカルカスタマイズ」とみなして
# 温存するため、_tasks が実際に再実行されたか・その効果が反映されたかはこの往復では
# 検出できない（_tasks を空にしても該当チェックは素通りする）。_tasks の re-run 自体の検証は
# 下記の「ドリフトあり往復チェック」で行う。
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

echo "[scaffold-verify] copier update ドリフトあり往復チェック（#701: _tasks が実際に再実行されることを検証）"
# 上のHEAD→HEAD往復では検出できない「_tasksがupdate時に正しく再実行されるか」を、実際に
# テンプレート側へドリフトを注入して検証する。#702（マーカー除去）・#704（テンプレートADR
# 削除）はいずれも「_tasksで生成後にファイル/ブロックを消す」実装になるため、代表として
# 「_tasksでファイルを削除する」パターンを使う。
#
# 手順（実機検証で確認済みの唯一確実な方法）: 同じスクラッチクローンを「テンプレートの現在版」
# として使い続け、その上に新しいコミット（ドリフト）を積む。生成済みプロジェクトの
# .copier-answers.yml の _src_path を後から別のクローンへ向け直す方式は、3-way merge の
# 比較基準がずれるためか _tasks の効果が反映されないことを実機で確認済み（採用しない）。
DRIFT_SRC="$WORK/drift-src"
git clone -q "$REPO_ROOT" "$DRIFT_SRC"
SENTINEL_FILE="TASKS_UPDATE_SENTINEL_701.md"
echo "#701 の往復チェック専用ダミーファイル（copier update で削除されるはず）" \
  > "$DRIFT_SRC/$SENTINEL_FILE"
(
  cd "$DRIFT_SRC"
  git add -A
  git -c user.email=scaffold-verify@example.invalid -c user.name=scaffold-verify \
    commit -q -m "scaffold-verify: add sentinel file for #701 drift test"
)

GEN_DRIFT_BASE="$WORK/generated-drift-base"
copier copy \
  --vcs-ref=HEAD \
  --data "project_name=$TEST_PROJECT_NAME" \
  --data "github_org=$TEST_GITHUB_ORG" \
  --data "github_repo=$TEST_PROJECT_NAME" \
  --data "aws_region=$TEST_AWS_REGION" \
  --defaults --trust \
  "$DRIFT_SRC" "$GEN_DRIFT_BASE" >/dev/null

GEN_DRIFT_UPDATED="$WORK/generated-drift-updated"
cp -r "$GEN_DRIFT_BASE" "$GEN_DRIFT_UPDATED"
(
  cd "$GEN_DRIFT_UPDATED"
  git init -q
  git -c user.email=scaffold-verify@example.invalid -c user.name=scaffold-verify add -A
  git -c user.email=scaffold-verify@example.invalid -c user.name=scaffold-verify \
    commit -q -m "scaffold-verify: initial generation (drift base)"
)

# ドリフト: 同じ $DRIFT_SRC に「_tasks でセンチネルファイルを削除する」コミットを積む。
# これが「テンプレートの次のバージョン」になる。
printf '\n  - "rm -f %s"\n' "$SENTINEL_FILE" >> "$DRIFT_SRC/copier.yml"
(
  cd "$DRIFT_SRC"
  git add -A
  git -c user.email=scaffold-verify@example.invalid -c user.name=scaffold-verify \
    commit -q -m "scaffold-verify: delete sentinel via _tasks (simulated template update)"
)

(
  cd "$GEN_DRIFT_UPDATED"
  copier update --trust --defaults --vcs-ref=HEAD
)

if [[ -f "$GEN_DRIFT_UPDATED/$SENTINEL_FILE" ]]; then
  echo "[scaffold-verify] NG: _tasks によるファイル削除が copier update で反映されていません" \
    "（$SENTINEL_FILE が残存）。_tasks が update 時に再実行されていない可能性があります" >&2
  exit 1
fi
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
