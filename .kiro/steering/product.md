# Product Overview

`devcon`（`devcon`）は、Dev Container 上で動く **Web アプリ＋その AWS インフラ（IaC）を
ひとまとめにしたモノレポのテンプレート**。JAWS-UG 岩松コミュニティ向けに、「AI（Claude Code /
Copilot）と一緒に、ガードレール付きで AWS アプリ開発を一周体験できる」ことを狙う教材兼ひな型。

## Core Capabilities

- **再現可能な開発環境**: Dev Container に Terraform / AWS CLI / Python / Node / Claude Code を
  プリインストール。クローンしてすぐ `make dev` で動く。
- **3 層アプリのひな型**: 静的 SPA（web）＋ ステートレス JSON API（api）＋ PostgreSQL。
  `items` の参照系 CRUD ＋ `health` を骨組みとして持つ。
- **キーレス CI/CD**: GitHub OIDC でジョブ単位の IAM ロールを引き受け、長期 AWS キーなしで
  plan/apply・デプロイ。
- **AI 開発ガードレール**: `CLAUDE.md` 群・`.claude/settings.json`・`docs/` で「やってはいけない
  こと」を明文化し、Copilot 用 `.github/instructions/*` にもミラー。

## Target Use Cases

- 勉強会・ハンズオンで「テンプレートを fork → 自分の AWS で実開発」までを体験する。
- 小さな新機能を、要件定義 → 基本設計 → 実装 → CI green まで通して学ぶ。
- インフラ（Terraform）変更を OIDC キーレス CD の作法で安全に試す。

## Value Proposition

「実装フェーズのガードレールが最初から効いている」こと。AI に曖昧な指示で書かせるのではなく、
`docs/` を正とした規約・1 issue 1 PR・CI green の運用が組み込まれており、上流工程（業務整理〜
基本設計）も SDD（このディレクトリ）で残せる。

---

_Focus on patterns and purpose, not exhaustive feature lists_
