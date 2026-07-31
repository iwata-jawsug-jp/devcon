#!/usr/bin/env bash
# 任意のツリー（開発用リポジトリ本体・publish-to-public.sh の変換後ツリー・copier 生成物など）に
# 対する内部整合チェック。#699（ADR-0028 実装フェーズ①）。verify-scaffold.sh がテンプレート化の
# 機構（除外リスト・sed置換）が壊れていないかを検証するのに対し、本スクリプトは「そのツリー単体で
# 相対リンクが辿れるか」「2つのツリーの中身が一致するか」だけを見る、ツリーの種類に依存しない
# 汎用チェック。#700（分類マニフェスト）導入後、分類違反チェックもここに追加する想定。
#
# --strict を渡さない限り、問題を検出しても常に exit 0 で終わる（探索的なローカル調査用）。
# `make tree-health`・CI（reusable-tree-health.yml）は Epic #698 の完了により既定で --strict を
# 渡す（blocking）。
#
# Usage:
#   check-tree-health.sh <dir> [--label LABEL] [--strict]
#     指定ツリー配下の Markdown 相対リンクを全走査し、解決できないものを報告する。
#
#   check-tree-health.sh --diff <dirA> <dirB> [--label LABEL] [--strict]
#     2つのツリーのファイル一覧（相対パス）を比較し、片方にしか無いファイルを報告する
#     （課題D: 起点ツリーにより生成先の成果物が変わる問題の検出用）。中身の差分は見ない。
set -euo pipefail

STRICT=0
LABEL=""
MODE="link"
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --diff)
      MODE="diff"
      shift
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    --label)
      if [[ $# -lt 2 ]]; then
        echo "usage: check-tree-health.sh ... --label LABEL (値が指定されていません)" >&2
        exit 2
      fi
      LABEL="$2"
      shift 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [[ "$MODE" == "link" ]]; then
  if [[ ${#POSITIONAL[@]} -ne 1 ]]; then
    echo "usage: check-tree-health.sh <dir> [--label LABEL] [--strict]" >&2
    exit 2
  fi
  TARGET_DIR="${POSITIONAL[0]}"
  [[ -z "$LABEL" ]] && LABEL="$TARGET_DIR"
  if [[ ! -d "$TARGET_DIR" ]]; then
    echo "check-tree-health.sh: ディレクトリが存在しません: $TARGET_DIR" >&2
    exit 2
  fi
else
  if [[ ${#POSITIONAL[@]} -ne 2 ]]; then
    echo "usage: check-tree-health.sh --diff <dirA> <dirB> [--label LABEL] [--strict]" >&2
    exit 2
  fi
  DIR_A="${POSITIONAL[0]}"
  DIR_B="${POSITIONAL[1]}"
  [[ -z "$LABEL" ]] && LABEL="$DIR_A vs $DIR_B"
  for d in "$DIR_A" "$DIR_B"; do
    if [[ ! -d "$d" ]]; then
      echo "check-tree-health.sh: ディレクトリが存在しません: $d" >&2
      exit 2
    fi
  done
fi

GITHUB_ACTIONS="${GITHUB_ACTIONS:-false}"

python3 - "$MODE" "$LABEL" "$STRICT" "$GITHUB_ACTIONS" "${TARGET_DIR:-}" "${DIR_A:-}" "${DIR_B:-}" <<'PYEOF'
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

mode, label, strict, gha, target_dir, dir_a, dir_b = sys.argv[1:8]
strict = strict == "1"
gha = gha == "true"

# ビルド成果物・依存パッケージ配下は Markdown を無差別に大量に含み得るため走査対象から除く。
# ローカル実行（make setup/scaffold-verify 済みの作業ツリー）での誤検知・時間浪費を防ぐための
# 保険。copier 生成物・publish-to-public.sh の dry-run 出力にはそもそも含まれない。
PRUNE_DIRS = {
    ".git",
    "node_modules",
    ".venv",
    ".terraform",
    "__pycache__",
    ".ruff_cache",
    ".mypy_cache",
    ".pytest_cache",
    "dist",
    ".next",
    "htmlcov",
}

# docs/adr/template.md の `[ADR-XXXX](xxxx-...)` はADRファイル名のプレースホルダ表記であり、
# 実在するリンクではない（#699 で明示的に除外対象と決めた唯一のケース）。将来同種のプレースホルダ
# が増えた場合はここにパスを足す。
PLACEHOLDER_FILES = {"docs/adr/template.md"}

FENCE_RE = re.compile(r"^(\s*)(```|~~~)")
INLINE_CODE_RE = re.compile(r"`[^`\n]*`")
LINK_RE = re.compile(r'\]\(\s*([^)\s]+)(?:\s+"[^"]*")?\s*\)')


def strip_code(text):
    """フェンス付きコードブロックの中身とインラインコードスパンを空行/空白に置き換える。
    行番号を保つため、削除ではなく同じ行数・同じ長さの空白で埋める。"""
    lines = text.split("\n")
    out = []
    fence = None
    for line in lines:
        m = FENCE_RE.match(line)
        if fence is None and m:
            fence = m.group(2)
            out.append("")
            continue
        if fence is not None:
            if m and m.group(2) == fence:
                fence = None
            out.append("")
            continue
        out.append(INLINE_CODE_RE.sub(lambda mo: " " * len(mo.group(0)), line))
    return "\n".join(out)


def find_broken_links(root):
    root = Path(root)
    broken = []
    unreadable = []
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if d not in PRUNE_DIRS]
        for fn in fns:
            if not fn.endswith(".md"):
                continue
            p = Path(dp) / fn
            rel = p.relative_to(root).as_posix()
            if rel in PLACEHOLDER_FILES:
                continue
            # 壊れたシンボリックリンク・権限エラー等でファイル自体が読めないケースを、
            # ここでクラッシュさせず「壊れたリンク」と同種の問題として報告する
            # （非strictモードでも常にexit 0、という不変条件を守るため）。
            try:
                text = p.read_text(encoding="utf-8", errors="replace")
            except OSError as e:
                unreadable.append((rel, str(e)))
                continue
            clean = strip_code(text)
            seen_targets = set()
            for lineno, line in enumerate(clean.split("\n"), start=1):
                for m in LINK_RE.finditer(line):
                    target = m.group(1)
                    if target in seen_targets:
                        continue
                    scheme = urlsplit(target).scheme
                    if scheme:  # http(s):, mailto:, etc.
                        continue
                    if target.startswith("/"):  # サイト絶対パス（本リポジトリでは未使用）
                        continue
                    path_part = target.split("#", 1)[0]
                    if path_part == "":  # 同一ファイル内アンカーのみ
                        continue
                    resolved = (p.parent / path_part).resolve()
                    if not resolved.exists():
                        seen_targets.add(target)
                        broken.append((rel, lineno, target))
    return broken, unreadable


def find_tree_diff(root_a, root_b):
    def files(root):
        root = Path(root)
        out = set()
        for dp, dns, fns in os.walk(root):
            dns[:] = [d for d in dns if d not in PRUNE_DIRS]
            for fn in fns:
                out.add((Path(dp) / fn).relative_to(root).as_posix())
        return out

    a, b = files(root_a), files(root_b)
    only_a = sorted(a - b)
    only_b = sorted(b - a)
    return only_a, only_b


def annotate(msg):
    if gha:
        print(f"::warning::{msg}")
    else:
        print(f"  {msg}")


if mode == "link":
    broken, unreadable = find_broken_links(target_dir)
    if broken:
        print(f"[tree-health] {label}: 解決できないリンクが {len(broken)} 件あります")
        for rel, lineno, target in broken:
            annotate(f"{rel}:{lineno} -> {target}")
    if unreadable:
        print(f"[tree-health] {label}: 読み込めないファイルが {len(unreadable)} 件あります")
        for rel, err in unreadable:
            annotate(f"{rel}: 読み込みエラー ({err})")
    print(
        f"[tree-health] label={label} mode=link "
        f"broken_links={len(broken)} unreadable_files={len(unreadable)}"
    )
    issues = len(broken) + len(unreadable)
else:
    only_a, only_b = find_tree_diff(dir_a, dir_b)
    total = len(only_a) + len(only_b)
    if total:
        print(f"[tree-health] {label}: ファイル差分が {total} 件あります")
        for rel in only_a:
            annotate(f"{dir_a} のみに存在: {rel}")
        for rel in only_b:
            annotate(f"{dir_b} のみに存在: {rel}")
    print(f"[tree-health] label={label} mode=diff diff_files={total}")
    issues = total

if strict and issues:
    sys.exit(1)
sys.exit(0)
PYEOF
