#!/usr/bin/env bash
#
# GitHub Codespaces で新規に作成したコンテナ上で、Claude Code の初回オンボーディング画面と
# 「このフォルダを信頼しますか」トラストダイアログをスキップできるよう ~/.claude/.claude.json
# を用意する。
#
# 名前付きボリューム（docs/development-environment.md §6）は同一 Codespace 内の Rebuild
# Container には効くが、Codespace 自体を新規に作り直すと別ボリュームになるため引き継がれず、
# 対話プロンプトが再度出る。
#
# 既存の ~/.claude/.claude.json がある場合、他の設定（MCP・プロジェクト履歴等）を壊さない
# よう対象の2キーだけを python3 でマージする（cat での単純上書きはしない）。
#
# Usage: ./tools/script/claude-codespaces-setup.sh
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
REPO_PATH="$(pwd)"
CLAUDE_JSON="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.claude.json"

mkdir -p "$(dirname "$CLAUDE_JSON")"

python3 - "$CLAUDE_JSON" "$REPO_PATH" <<'PYEOF'
import json
import sys

path, repo_path = sys.argv[1], sys.argv[2]

try:
    with open(path) as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}

config["hasCompletedOnboarding"] = True
config.setdefault("projects", {}).setdefault(repo_path, {})["hasTrustDialogAccepted"] = True

with open(path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PYEOF

echo "wrote $CLAUDE_JSON (hasCompletedOnboarding=true, projects[\"$REPO_PATH\"].hasTrustDialogAccepted=true)"
