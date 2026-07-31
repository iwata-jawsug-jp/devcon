#!/usr/bin/env bash
# 除外先ドキュメントへの参照（主題行の削除 + リンクのプレーンテキスト化）を除去する
# 共有実装。ADR-0028 D2（#703、Epic #698）。公開導線（publish-to-public.sh）と
# copier 導線（copier.yml の _tasks）の両方から、対象パスの一覧だけを変えて呼ぶ。
# 元は publish-to-public.sh 内の clean_excluded_doc_references() だったものを切り出した。
#
# 使い方: clean-excluded-doc-references.sh <fragment> [fragment...] -- <file> [file...]
#   fragment は正規表現の断片（basename ベース、ERE）。呼び出し側（publish-to-public.sh /
#   copier.yml の _tasks 経由で tools/script/gen-audience-excludes.py が生成）が、
#   ファイルなら `name\.ext` を、ディレクトリなら `name\/[^()]*` を組み立てて渡す。
#   `--` で対象パスリストとファイルリストを区切る。
#
# 「特定文字列を含む行を丸ごと削除」だと、他の内容と同居する行まで巻き込んで壊れる
# （#287: CHANGELOG の1文中の引用まで巻き込んで行が壊れた）。安全のため2段階に分ける:
#   1. 箇条書き/テーブル行の「主題」が除外先自身である行だけを丸ごと削除する
#      （例: `- \`docs/release.md\` — 説明` や `| [proposal/](proposal/) | ... |`）。
#      行頭の bullet/pipe の直後に来ている＝その行の存在理由が除外先の説明そのもの、という前提。
#   2. 残った行にある除外先への実リンク（`[label](.../release.md)` 等）はリンク部分の飾りだけを
#      外してラベルのプレーンテキストに変換する（リンク先が無いのでリンクとしては壊れているが、
#      文自体は保持する）。
#   バッククォートだけで触れている地の文（例: 「`docs/release.md` に明記」）はクリック可能な
#   リンクではないため対象外とし、そのまま残す。対象はテキストファイル全般ではなく Markdown
#   （呼び出し側が *.md のみを渡す想定）。
set -euo pipefail

fragments=()
while [[ $# -gt 0 && "$1" != "--" ]]; do
  fragments+=("$1")
  shift
done
[[ "${1:-}" == "--" ]] && shift

[[ ${#fragments[@]} -gt 0 ]] || exit 0
[[ $# -gt 0 ]] || exit 0

alt="$(
  IFS='|'
  echo "${fragments[*]}"
)"

for f in "$@"; do
  [[ -f "$f" ]] || continue
  sed -i -E "/^[[:space:]]*[|*-][[:space:]]*[*_\`\[]*[^]\`()[:space:]]*(${alt})/d" "$f"
  # フラグメントの直後に `)` を要求せず、末尾に `[^()]*` を足して見出しアンカー
  # （`file.md#section`）等の残りの URL 部分も飲み込めるようにする（実機の tree-health
  # チェックで発覚: `docs/scaffold-cli.md#copier-update...` のようなアンカー付き自己リンクが
  # 末尾非マッチで素通りしていた）。
  sed -i -E "s/\[([^][]*)\]\([^()]*(${alt})[^()]*\)/\1/g" "$f"
done
