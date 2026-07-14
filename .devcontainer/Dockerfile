FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# ツールバージョンの単一ソース（#109）。
# - TERRAFORM_VERSION は CI の pin（ci.yml / cd-infra.yml の terraform_version）と必ず同時に更新する。
#   state を書くのは CI なので CI 側の pin が正。
# - 更新手順は docs/development-environment.md の「ツールバージョンの更新手順」を参照。
# - Node.js は CI（node-version: 24）と同じく major のみ固定（下の setup_24.x）。
# - AWS CLI v2 / gh / Claude Code は CI のゲート（fmt/lint/test/security）対象ツールではなく
#   結果の再現性に影響しないため、意図的に latest のまま。
ARG TERRAFORM_VERSION=1.13.0
ARG TFLINT_VERSION=0.63.1
ARG TRIVY_VERSION=0.71.2
ARG CHECKOV_VERSION=3.3.2
ARG UV_VERSION=0.11.24
ARG COPIER_VERSION=9.17.0

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

# Node.js 24 — CI（ci.yml / cd-app.yml の node-version: 24）と同じく major のみ固定（minor は float）
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
    && apt-get install -y --no-install-recommends "terraform=${TERRAFORM_VERSION}-*" \
    && rm -rf /var/lib/apt/lists/*

# TFLint
RUN curl -fsSL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh \
    | TFLINT_VERSION="v${TFLINT_VERSION}" bash

# Trivy (Aqua Security APT repo)
RUN curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor -o /usr/share/keyrings/trivy.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/trivy.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends "trivy=${TRIVY_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

# Checkov
RUN python3.14 -m pip install --no-cache-dir "checkov==${CHECKOV_VERSION}"

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
# NOTE: GitHub Copilot CLI への切り替え検討は https://github.com/iwata-jawsug-jp/devcon/issues/117 を参照
RUN mkdir -p /home/vscode/.npm-global \
    && npm install -g @anthropic-ai/claude-code

# uv (Astral) — vscode ユーザーのローカルにインストール
RUN curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh

# copier（#294 スキャフォールドCLI。make scaffold-verify / ci.yml の scaffold ジョブで使う）
RUN /home/vscode/.local/bin/uv tool install "copier==${COPIER_VERSION}"
