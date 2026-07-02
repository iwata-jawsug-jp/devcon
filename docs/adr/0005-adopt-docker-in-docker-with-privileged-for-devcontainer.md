# ADR-0005: Dev Container の Docker 実行方式として docker-in-docker（--privileged）を採用する

- **Status:** Accepted
- **Date:** 2026-07-02
- **Deciders:** itouhi
- **Related:** #116, #108（開発環境としての評価 §改善6）,
  [ADR-0001](0001-record-architecture-decisions.md),
  [docs/development-environment.md](../development-environment.md)

## Context

本リポジトリの開発は Dev Container 上で完結させる方針であり、コンテナ内から Docker を使う
場面がある（`make dev` の Postgres コンテナ、`docker compose`、コンテナイメージのローカル
ビルド検証など）。現行の `.devcontainer/devcontainer.json` は
[docker-in-docker feature](https://github.com/devcontainers/features/tree/main/src/docker-in-docker)
＋ `runArgs: ["--privileged"]` で devcontainer 内に独立した Docker デーモンを立てており、
レイヤーキャッシュは名前付きボリューム `devcon-dind`（`/var/lib/docker`）で rebuild を
またいで永続化済み。

一方、devcontainer で Docker を使う方式には
[docker-outside-of-docker](https://github.com/devcontainers/features/tree/main/src/docker-outside-of-docker)
（ホストの Docker ソケットをコンテナに共有し、ホストのデーモンを使う。以下 DooD）という
有力な代替がある。DooD なら `--privileged` が不要でホストのイメージキャッシュも共有できる
ため、「なぜ広い特権を持つ DinD なのか」はどちらにも転び得る設計判断であり、ADR 運用
（[ADR-0001](0001-record-architecture-decisions.md)）に従い根拠を記録する。

### 選択肢の比較

| 観点                             | A. docker-in-docker（現行）                                                                         | B. docker-outside-of-docker（ホストソケット共有）                                                                                 | C. Docker なし                                            |
| -------------------------------- | --------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| 特権範囲                         | ✗ `--privileged` が必要。コンテナ→ホストカーネル方向の広い権限を持つ                                | ◎ 特権不要（ソケットの bind mount のみ）。ただしソケット経由でホストのデーモンを完全操作できる点は実質 root 相当                  | ◎ 特権不要                                                |
| ホスト分離性                     | ◎ デーモン・イメージ・コンテナがすべて devcontainer 内で完結。ホストの Docker 環境を汚さない        | ✗ 生成したイメージ・コンテナ・ネットワークがホスト側に直接残る                                                                    | ◎（そもそも使わない）                                     |
| イメージキャッシュ効率           | △ ホストとキャッシュを共有できない。ただし `devcon-dind` ボリュームで rebuild 間は永続化済み | ◎ ホストのキャッシュをそのまま共有。pull のやり直しが発生しない                                                                   | —                                                         |
| ポート・パスのマッピング         | ◎ デーモンが同一環境内にあるため、bind mount のパスも `-p` のポートも devcontainer 視点で素直に動く | ✗ 起動したコンテナはホスト上の「兄弟」になる。bind mount はホスト側のパスを要求し（workspace パスのずれ）、ポートはホスト側に開く | —                                                         |
| 複数リポジトリ併用時の干渉       | ◎ リポジトリ（devcontainer）ごとにデーモンが独立し、コンテナ名・ポート・ネットワークが衝突しない    | ✗ 全 devcontainer がホストの単一デーモンを共有するため、名前・ポートの衝突や `docker ps` の混線が起きうる                         | ◎                                                         |
| ホスト OS 依存（WSL2 / macOS）   | ◎ ホスト側は devcontainer を 1 個動かせればよく、ホストの Docker 構成に依存しない                   | △ ホストのデーモンの挙動（Docker Desktop / WSL2 / rancher 等）に依存し、環境差が devcontainer 内に漏れる                          | ◎                                                         |
| リソースオーバーヘッド           | △ デーモン二重起動＋専用ボリュームのディスク消費                                                    | ◎ 追加デーモンなし                                                                                                                | ◎                                                         |
| 本リポジトリのワークフロー適合性 | ◎ `make dev`（Postgres）等がそのまま動く                                                            | ○ 動くが上記のパス/ポート/干渉の注意が要る                                                                                        | ✗ `make dev` の DB 起動やイメージのローカル検証ができない |

## Decision

**docker-in-docker（`--privileged`）を継続採用する。分離性を最優先する。**

- **分離性を優先する。** デーモン・イメージ・コンテナが devcontainer 内で完結し、ホストの
  Docker 環境を汚さず・依存しない。「ホストに必要なのは Docker / VS Code / Dev Containers
  拡張だけ」という本リポジトリの開発環境方針（[docs/development-environment.md](../development-environment.md)）
  と一貫する。複数リポジトリの devcontainer を併用しても互いに干渉しない。
- **DinD の主な弱点であるキャッシュ効率は、既に `devcon-dind` ボリューム
  （`/var/lib/docker` の永続化）で緩和済み。** rebuild のたびにイメージを取り直す問題は解消
  されており、残る差はホストとのキャッシュ共有のみで、許容できる。
- **`--privileged` はコンテナ→ホスト方向のリスクだが、許容する。** この devcontainer は
  自分でビルドする信頼済みイメージ（`.devcontainer/Dockerfile`）を自分の開発にのみ使う環境
  であり、未知・非信頼のコードを特権コンテナで動かすユースケースではない。なお DooD も
  ソケット経由でホストのデーモンを完全操作できる（実質 root 相当）ため、「特権が不要＝安全」
  とは言い切れず、リスクの差は見た目ほど大きくない。
- **却下案 B（docker-outside-of-docker）:** 特権不要・ホストとキャッシュ共有・デーモン
  二重起動なしという利点は明確だが、生成物がホスト側に残る（分離性の喪失）、bind mount が
  ホスト側パスを要求する、複数リポジトリ併用でデーモンを共有して干渉する、ホストの Docker
  構成（WSL2 / macOS / Docker Desktop の差）に依存する、という点が本リポジトリの
  「ホストを汚さない・依存しない」方針に反するため採らない。
- **却下案 C（Docker なし）:** `make dev` の Postgres 起動やコンテナイメージのローカル検証が
  できなくなり、開発ワークフローが成立しないため採らない。

## Consequences

- **良い面:** ホスト分離性と再現性が保たれる。パス・ポートのマッピングが素直で、
  `docker compose` ベースのローカル開発（`make dev`）が devcontainer 視点のまま動く。
  ホスト OS（WSL2 / macOS）による挙動差を devcontainer 内に持ち込まない。
- **受け入れるコスト:**
  - `runArgs: ["--privileged"]` が残り続ける。devcontainer はホストカーネルに対する広い
    権限を持つため、**この devcontainer で非信頼のイメージ・コードを動かさない**という
    運用前提が付く。
  - Docker デーモンの二重起動と `devcon-dind` ボリュームのディスク消費。肥大化した
    場合は `docker system prune` またはボリューム削除（[docs/development-environment.md §6](../development-environment.md)）
    でリセットする。
  - ホストのイメージキャッシュは共有されない（初回 pull は devcontainer 側でも発生する）。
- **再検討トリガー:** 次のいずれかが起きたら本 ADR を見直し、新 ADR で更新する。
  - docker-in-docker feature 側で **rootless DinD** 等の特権縮小オプションが安定し、
    `--privileged` なしで現行ワークフローが成立するようになったとき。
  - この devcontainer で非信頼のコード・イメージを扱う要件が生じ、`--privileged` の
    リスク許容の前提が崩れたとき。
  - dind ボリュームのディスク消費やデーモン二重起動のオーバーヘッドが、開発マシンで
    実害になったとき（そのときは DooD への移行を別 PR で検討する）。
