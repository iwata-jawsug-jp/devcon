#!/usr/bin/env bash
# マウントした永続ボリュームを vscode 所有に整え、bash 履歴を永続化する。
# devcontainer rebuild のたびに postCreateCommand から実行される（冪等）。
set -euo pipefail

# 名前付きボリュームは root 所有で作成されるため vscode に付け替える
for d in "$HOME/.aws" "$HOME/.config/gh" "$HOME/.claude" "$HOME/.history"; do
  sudo mkdir -p "$d"
  sudo chown -R vscode:vscode "$d"
done

# bash 履歴を永続ボリューム上のファイルに保存する（rebuild をまたいで残す）
hist="$HOME/.history/.bash_history"
touch "$hist"
marker='HISTFILE="$HOME/.history/.bash_history"'
if ! grep -qF "$marker" "$HOME/.bashrc"; then
  {
    echo ''
    echo '# --- devcontainer: persist shell history on a volume ---'
    echo 'export HISTFILE="$HOME/.history/.bash_history"'
    echo 'export HISTSIZE=100000'
    echo 'export HISTFILESIZE=200000'
    echo 'export PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}"'
  } >> "$HOME/.bashrc"
fi
