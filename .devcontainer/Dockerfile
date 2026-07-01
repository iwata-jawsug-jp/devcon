FROM mcr.microsoft.com/devcontainers/base:ubuntu-22.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        software-properties-common \
        unzip \
        git \
        build-essential \
        ripgrep \
    && rm -rf /var/lib/apt/lists/*

# Python 3.14
RUN add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        python3.14 \
        python3.14-venv \
        python3.14-dev \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --install /usr/bin/python python /usr/bin/python3.14 1 \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.14 1 \
    && python3.14 -m ensurepip --upgrade \
    && python3.14 -m pip install --no-cache-dir --upgrade pip

# Node.js 24
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# AWS CLI v2
RUN arch="$(uname -m)" \
    && case "$arch" in \
        x86_64)  aws_arch="x86_64" ;; \
        aarch64) aws_arch="aarch64" ;; \
        *) echo "Unsupported arch: $arch" && exit 1 ;; \
    esac \
    && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip

# Terraform (HashiCorp APT repo)
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/hashicorp.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends terraform \
    && rm -rf /var/lib/apt/lists/*

# TFLint
RUN curl -fsSL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash

# Trivy (Aqua Security APT repo)
RUN curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor -o /usr/share/keyrings/trivy.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/trivy.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends trivy \
    && rm -rf /var/lib/apt/lists/*

# Checkov
RUN python3.14 -m pip install --no-cache-dir checkov

# GitHub CLI (gh)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

USER vscode
ENV NODE_OPTIONS=--no-deprecation
ENV NPM_CONFIG_PREFIX=/home/vscode/.npm-global
ENV PATH=/home/vscode/.local/bin:/home/vscode/.npm-global/bin:$PATH
# TODO: GitHub Copilot CLI への切り替えを検討中（未実施）。切り替える場合の手順:
#   1. 下記 RUN の `@anthropic-ai/claude-code` を `@github/copilot`（npm, Node.js 22+ 要）に置き換える。
#      パッケージ名は要検証: https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli
#      （旧 `@githubnext/github-copilot-cli` はサポート終了、混同しないこと）
#   2. 初回起動時に `/login` での GitHub 認証（要 Copilot サブスクリプション）が発生するため、
#      Dev Container 起動後の初期セットアップ手順（README / docs/development-environment.md）に追記する。
#   3. `.claude/skills/kiro-*` は docs/sdd.md の記載どおり Copilot CLI からも利用可能な想定だが、
#      実際の起動コマンド・スラッシュコマンド互換性（.github/copilot-instructions.md 参照）を実機で再検証する。
#   4. CLAUDE.md 群と .github/instructions/* のミラー運用（docs/ai-instructions.md）は
#      Claude Code 前提の記述が残っていないか棚卸しする。
#   5. Claude Code を完全に廃止するか、両方インストールして併用するかを決め、後者の場合は
#      本コメントの TODO ではなく、両方の npm install を残す形に変更する。
RUN mkdir -p /home/vscode/.npm-global \
    && npm install -g @anthropic-ai/claude-code

# uv (Astral) — vscode ユーザーのローカルにインストール
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
