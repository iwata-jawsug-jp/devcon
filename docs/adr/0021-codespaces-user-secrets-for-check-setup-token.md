# ADR-0021: 確認スクリプト用トークンは GitHub Codespaces のユーザーシークレットを優先する

- **Status:** Accepted
- **Date:** 2026-07-20
- **Deciders:** itouhi
- **Related:** #516, [development-environment.md](../development-environment.md)「GitHub
  Codespaces では」節, `tools/script/check-devenv-setup.sh`,
  `tools/script/check-repo-vars.sh`, `.env.check-setup.example`,
  repository-variables-navigation-proposal.md（Phase 2 で
  `check-repo-vars.sh` が同じ仕組みを複製した経緯）

## Context

`check-devenv-setup.sh`（GitHub Rulesets・リポジトリ変数の登録確認）と
`check-repo-vars.sh`（リポジトリ変数のドリフト検知、Phase 2）はどちらも、GitHub
Codespaces の既定認証（Codespaces が自動注入する `GITHUB_TOKEN`）では権限不足で判定できない
項目がある（#516: API によって権限が異なり、GitHub Rulesets は読めても Actions の
リポジトリ変数は読めない、といったケース）。この場合スクリプトは「未登録」と誤判定せず
「権限不足で確認できない」旨のスキップ表示にする設計だが、正確に判定したい開発者は
確認専用の最小権限 PAT（Fine-grained PAT、`Administration: Read-only` +
`Variables: Read-only`、対象リポジトリ限定・短期有効期限）を発行し、`.env.check-setup.example`
から生成した `.env.check-setup`（git-ignored）に `GH_CHECK_SETUP_TOKEN=...` として保存する
運用になっている。両スクリプトはこのファイルを個別に読む同じ8行程度のブロックを重複して持つ。

**この運用は GitHub Codespaces と相性が悪い。** `.env.check-setup` は git-ignore された
リポジトリ内のファイルであり、Codespaces を作り直す（新しい Codespace を作成する）たびに
消える。ローカルの Docker Desktop 経由の devcontainer ならホスト側にチェックアウトした
リポジトリのファイルがコンテナ再構築後も残るためこの問題は起きにくいが、Codespaces は
GitHub 側の仮想マシンにリポジトリを都度クローンする方式のため、develpoer は新しい
Codespace を作るたびに毎回 PAT を発行し直して `.env.check-setup` を作り直す必要がある
（Phase 2 で `check-repo-vars.sh` が増えたことで、この面倒さが変わるわけではないが、
同じ仕組みを使うスクリプトが2本に増えた）。

GitHub Codespaces には、この種の「個人の PAT を Codespace 起動時に自動で環境変数として
注入する」ための専用機能がある: **ユーザー個人の Codespaces シークレット**
（`github.com/settings/codespaces` → Codespaces secrets）。リポジトリ/Organization側の
Codespaces シークレット（repo管理者が設定し全利用者に共有される）とは別物で、GitHubアカウント
個人の設定として、シークレットごとに「どのリポジトリの Codespace で使えるか」を選択する。
選択したリポジトリの Codespace を作成すると、リポジトリ側の設定（`devcontainer.json` の変更
なども）なしに、そのシークレットが環境変数として自動的に注入される。

## Decision

**`GH_CHECK_SETUP_TOKEN` は、GitHub Codespaces のユーザー個人シークレットからの自動注入を
第一の入手経路とし、`.env.check-setup` は非 Codespaces（ローカル Docker Desktop 等）向けの
フォールバックとして残す。**

### 採用する設計

1. **スクリプト側の変更（`check-devenv-setup.sh` / `check-repo-vars.sh` 共通）**:
   既に環境変数 `GH_CHECK_SETUP_TOKEN` がセットされていればそれを優先し、`.env.check-setup`
   の読み込みで上書きしない。ファイルは環境変数が空のときのみのフォールバックにする。

   ```bash
   # 変更前（両スクリプトに重複）
   GH_CHECK_SETUP_TOKEN=""
   if [[ -f .env.check-setup ]]; then
     GH_CHECK_SETUP_TOKEN="$(grep -m1 '^GH_CHECK_SETUP_TOKEN=' .env.check-setup | cut -d= -f2-)"
   fi

   # 変更後
   GH_CHECK_SETUP_TOKEN="${GH_CHECK_SETUP_TOKEN:-}"
   if [[ -z "$GH_CHECK_SETUP_TOKEN" && -f .env.check-setup ]]; then
     GH_CHECK_SETUP_TOKEN="$(grep -m1 '^GH_CHECK_SETUP_TOKEN=' .env.check-setup | cut -d= -f2-)"
   fi
   ```

   Codespaces のユーザーシークレットは devcontainer 内で素の環境変数として現れるため、
   スクリプト側はこの2行の変更だけで両方の経路に対応できる（Codespaces かどうかの分岐は
   スクリプト本体には不要）。

2. **`CODESPACES` 環境変数によるガイダンスの出し分け**: 環境変数も `.env.check-setup` も
   無い場合の案内メッセージを、GitHub が Codespaces 上で自動セットする `CODESPACES=true`
   の有無で切り替える。Codespaces上ならユーザーシークレットの設定手順を、そうでなければ
   従来どおり `.env.check-setup.example` の手順を案内する。

3. **`.env.check-setup.example` のコメント更新**: 冒頭に「GitHub Codespaces を使っている
   場合は、このファイルの代わりに `github.com/settings/codespaces` でユーザーシークレット
   `GH_CHECK_SETUP_TOKEN`（対象リポジトリ: このリポジトリを選択）を設定することを推奨」
   という一文を追加する。ファイル自体・中身のPAT発行手順（scope: `Administration: Read-only`
   - `Variables: Read-only`）は変更しない。

4. **`docs/development-environment.md`「GitHub Codespaces では」節の更新**: 現状の
   「`.env.check-setup.example` の手順に従って...」という案内を、Codespaces 利用時は
   ユーザーシークレットを第一候補として案内する形に書き換える。あわせて、シークレットの
   追加/変更は**既存の起動中 Codespace には自動反映されない場合があり**、Codespace の
   再起動（stop → start）または再作成が必要になりうる旨を明記する（GitHub 側の挙動であり
   このリポジトリ側で制御できないため、注意書きとして案内するに留める）。

### 見送った代替案

- **リポジトリ/Organization の Codespaces シークレットにする（repo 管理者が設定し全員で共有）**:
  却下。このトークンは各開発者が自分の GitHub 権限で発行する個人の Fine-grained PAT であり、
  最小権限化・失効管理は発行者本人が担うべきもの。共有シークレットにすると「誰の PAT か」
  が曖昧になり、ローテーション・失効の運用責任も不明確になる。
- **`.env.check-setup` を dotfiles リポジトリ経由で自動配置する**: 却下。Codespaces の
  dotfiles 機能自体は存在するが、秘密情報を dotfiles リポジトリに置く運用は「dotfiles
  リポジトリ自体の可視性・共有範囲」という別のセキュリティ課題を生み、CLAUDE.md の
  「`.env` は git-ignore・秘密は git に入れない」という既存原則とも相性が悪い。Codespaces
  ユーザーシークレットは秘密情報の受け渡し専用の仕組みであり、この用途に最も合致する。
  - リポジトリ変数 `GH_CHECK_SETUP_TOKEN`（GitHub Actions の Variables/Secrets）にする案は
    検討の俎上にも上げていない — このトークンはローカル/Codespaces での**人間による手動確認**
    専用で、CI では使わない（CI は OIDC ロールで別途認証する）ため、GitHub Actions 側の
    仕組みに乗せる理由がない。
- **現状維持（`.env.check-setup` のみ）**: 却下。Codespace を作り直すたびに手動で PAT を
  発行し直す運用が続き、Phase 2（`check-repo-vars.sh`）で同じ仕組みを使うスクリプトが
  2本に増えたことで、このボトルネックの影響範囲も広がった。

## Consequences

- **良い面:**
  - 開発者ごとに一度（GitHub アカウント設定で）シークレットを登録すれば、以降作成する
    すべての新規 Codespace で自動的に有効になり、Codespace ごとの `.env.check-setup` 再作成が
    不要になる。
  - ローカル Docker Desktop 経由の devcontainer 利用者への影響はない（`.env.check-setup` の
    運用は変更なし、後方互換）。
  - スクリプト側の変更は最小（環境変数を上書きしないようにする数行×2ファイル）で、
    新しい依存やCI変更を伴わない。
- **トレードオフ:**
  - ユーザーシークレットの登録自体は GitHub の Web UI での手動操作が必要（スクリプトや
    `make setup` からの自動化はできない — 執筆時点で `gh` CLI に Codespaces ユーザー
    シークレットを操作するサブコマンドは無い認識）。
  - 既存の起動中 Codespace には反映されないことがあり、ドキュメントで注意喚起はするものの、
    「反映されずスクリプトが古い挙動のまま」という混乱が起きうる。
  - 非 Codespaces の devcontainer 利用者には恩恵がなく、`.env.check-setup` の手動運用が
    引き続き残る（二つの経路が並存し、ドキュメントは両方を説明し続ける必要がある）。
- **再検討トリガー:**
  - `gh` CLI が Codespaces ユーザーシークレットの作成/一覧をサポートしたら、
    `make check-setup` 側から「未設定なら作成コマンドを提示する」ところまでの自動化を検討する。
  - 複数人運用に変わり、確認用トークンを組織として一括配布したくなったら、見送った
    Organization Codespaces シークレット案を再検討する。
