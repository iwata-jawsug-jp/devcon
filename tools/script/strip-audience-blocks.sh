#!/usr/bin/env bash
# 公開導線（publish-to-public.sh）と copier 導線（copier.yml の _tasks）が共有する
# ブロック単位の除外の実装本体。ADR-0028 D2（#702、Epic #698）。
#
# マーカーで囲んだブロックを除去する。「特定文字列を含む行を削除」では複数行の項目が
# 壊れる（継続行だけ残る）ため、著者が明示的に印を付ける方式にする（#287 の実害を踏まえる。
# 元は publish-to-public.sh 内の strip_public_exclude_blocks() だったものを、copier 側からも
# 呼べるよう単独スクリプトへ切り出した）。
#
# 使い方: strip-audience-blocks.sh <no-publish|no-generate> <file> [file...]
#   no-publish  … 公開用ミラー（iwata-jawsug-jp/devcon）にも生成先にも出さないブロックを除去する
#                 （旧 public:exclude と等価。生成先にも出さない理由: 生成は開発用ツリー起点でも
#                 行われうるため、公開用ツリーを経由しない経路でも同じ除外が効く必要がある）。
#   no-generate … 公開用ミラーには残すが、copier 生成先には出さないブロックを除去する。
#
# マーカー記法（ファイルの種類ごとに同じ意味の2形式を認識する）:
#   HTML コメント（Markdown 等）: <!-- audience:no-publish --> ... <!-- /audience:no-publish -->
#   # コメント（YAML/シェル/Makefile 等）: # audience:no-publish ... # /audience:no-publish
#   （no-generate も同様）
#   互換のため、旧 <!-- public:exclude --> / <!-- /public:exclude --> は
#   audience:no-publish の別名として扱う。
set -euo pipefail

directive="${1:?usage: strip-audience-blocks.sh <no-publish|no-generate> <file> [file...]}"
shift

case "$directive" in
  no-publish | no-generate) ;;
  *)
    echo "strip-audience-blocks.sh: 未知の directive '$directive'（no-publish/no-generate のみ）" >&2
    exit 1
    ;;
esac

begin_html="<!-- audience:${directive} -->"
end_html="<!-- /audience:${directive} -->"
begin_hash="# audience:${directive}"
end_hash="# /audience:${directive}"

# 旧マーカーは no-publish の別名としてのみ効く。
legacy_begin=""
legacy_end=""
if [[ "$directive" == "no-publish" ]]; then
  legacy_begin="<!-- public:exclude -->"
  legacy_end="<!-- /public:exclude -->"
fi

for f in "$@"; do
  [[ -f "$f" ]] || continue
  grep -Iq . "$f" 2>/dev/null || continue # バイナリはスキップ

  if ! grep -qF -e "$begin_html" -e "$begin_hash" ${legacy_begin:+-e "$legacy_begin"} "$f"; then
    continue
  fi

  # 開始・終了の両マーカーを同じ1行に含む行（本スクリプト自身のドキュメント中の記法説明が
  # 該当し、公開導線がこのファイル自身にも no-publish 除去をかけるため実際に起こる）は、
  # 終了判定を優先して即座に skip を解除する。開始判定を先に見て `next` すると終了判定に
  # 到達せず skip が解除されないまま後続の無関係な行（実コード）まで巻き込んで消してしまう
  # （実機の CI で発覚・再現確認済み）。
  awk -v bh="$begin_html" -v eh="$end_html" -v bs="$begin_hash" -v es="$end_hash" \
    -v lb="$legacy_begin" -v le="$legacy_end" '
    {
      line = $0
      has_begin = (index(line, bh) || index(line, bs) || (lb != "" && index(line, lb)))
      has_end   = (index(line, eh) || index(line, es) || (le != "" && index(line, le)))
      if (has_begin || has_end) { skip = has_end ? 0 : 1; next }
      if (!skip) print
    }
  ' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
done
