# ADR-0019: Policy as Code (`infra/policy/`) の下流配布は専用機構を新設せず既存の仕組みに委ねる

- **Status:** Accepted
- **Date:** 2026-07-19
- **Deciders:** itouhi
- **Related:** #296, #298, #295, [ADR-0012](0012-reusable-workflow-in-repo-tag-versioned.md),
  [ADR-0017](0017-policy-as-code-conftest.md), [ADR-0010](0010-adopt-copier-for-scaffold-cli.md)

## Context

#296 は当初の見送り候補の一つとして「Policy as Code 基盤自体を #295（reusable workflow）経由で
下流リポジトリへ配布するかの検討」を残していた。#294（copier によるスキャフォールド）と #295
（reusable workflow 化、ADR-0012）が完了した今、`infra/policy/*.rego` という具体的な資産について
「下流リポジトリはどうやってこれを受け取り、更新に追従するのか」を整理する。

現状（下流の消費者リポジトリはまだ実在しない — #299 のハンズオン実証待ち）を調査した事実:

- **`copier.yml` の `_exclude` に `infra/policy/` の除外は無い。** つまり `copier copy`
  でプロジェクトを生成した時点で、`infra/policy/*.rego`（ポリシー本体）はそのまま下流リポジトリへ
  コピーされる。生成直後は何もしなくても Policy as Code が有効な状態で始まる。
- **`reusable-infra.yml`（#295, ADR-0012）は `working-directory: infra` で
  `conftest verify --policy policy` / `conftest test --policy policy ...` を実行する。**
  `uses: iwata-jawsug-jp/devcon/.github/workflows/reusable-infra.yml@<tag>` で呼び出す設計
  （ADR-0012）のため、`actions/checkout` は**呼び出し側（下流リポジトリ自身）** をチェックアウトする。
  つまりこのステップが検証するのは常に「呼び出し元リポジトリ自身の `infra/policy/`」であり、
  devcon 側の `infra/policy/` を参照しにいくわけではない。
- 上記2点を合わせると、**「ポリシーを実行するエンジン（conftest のバージョン・コマンド・3層配線）」と
  「ポリシーの中身（`*.rego` ファイル）」は別々の経路で下流に届く**:
  - エンジン側は reusable workflow のタグ参照により、devcon 側でタグを上げれば下流は
    (`v*` タグを追従する限り) 自動的に最新のコマンド・ツールバージョンを使う。
  - 中身側はスキャフォールド時点のスナップショットのままで、devcon 側で新しいポリシー
    （例: 今回の `s3_security.rego`）を追加しても下流には自動で伝わらない。
- この「中身側の追従」は #298（テンプレート更新の下流追従）が既に
  「(c) リポジトリ構造・設定ファイルは `copier update`」として一般化して扱おうとしている問題と
  完全に同型。`infra/policy/*.rego` はこの (c) 分類に単純に含まれる — 独自の配布経路を必要とする
  性質のファイルではない。
- **新たに判明したリスク:** 下流リポジトリが意図的に `infra/policy/` を削除・空にした場合
  （Policy as Code 自体をオプトアウトしたい場合）、`reusable-infra.yml` の
  `conftest verify --policy policy` は `Error: running verification: load: loading policies:
no policies found in [policy]` で **exit 1（CI 失敗）** になることをローカルで再現確認した。
  ディレクトリが存在しない/空という状態を握りつぶして skip する設計にはなっていない。

## Decision

**`infra/policy/*.rego` 専用の下流配布・追従機構は新設しない。** 既存の2つの仕組みにそのまま
委ねる:

1. **初回配布**: `copier copy`（#294）が現状のまま `infra/policy/` を丸ごとコピーする。
2. **エンジンの追従**: reusable workflow のタグ参照（#295, ADR-0012）が自動で処理する。
   下流が `v*` タグを追従する限り、conftest のバージョンや実行コマンドの改善は自動的に届く。
3. **ポリシー本文の更新追従**: #298 のスコープにそのまま合流させる。`infra/policy/*.rego` を
   #298 のカテゴリ (c)（`copier update` 対象）の一例として扱い、#296 側で重複した設計をしない。

一方で、**「`infra/policy/` が空/不在のときの `reusable-infra.yml` の挙動」は #298 側の
follow-up として記録する**（このADRでは実装しない — 下流の消費者が実在しない現時点では
「Policy as Code をオプトアウトしたい」という具体的なニーズも無く、対応の優先度を上げる理由が
無いため）。対応するなら例えば `conftest verify`/`conftest test` の前に
`hashFiles('infra/policy/**') != ''` で存在チェックし、無ければステップ自体をスキップする形が
考えられる。

## Consequences

- **良い面:** 新しい配布・バージョン管理の仕組みを増やさない。#298 が実装されれば
  `infra/policy/*.rego` の追従も自動的に解決する — #296 側で二重に設計・実装するコストを払わずに
  済む。
- **トレードオフ:**
  - #298 が実装されるまでは、下流リポジトリは devcon 側の新規ポリシー追加
    （今回の `s3_security.rego` 等）を手動で拾いにいく必要がある（`copier update` の実装待ち）。
  - `infra/policy/` を空/削除した下流リポジトリは、対応するまで `reusable-infra.yml` の
    `check` ジョブが恒常的に赤くなる。これは現状「意図せず踏むと分かりにくい」トラップとして
    残る。
- **再検討トリガー:**
  - #298（`copier update` によるテンプレート更新追従）が実装されたら、この ADR の decision 1〜3 を
    実際の下流リポジトリ（#299 のハンズオン、または `itouhi/devcon-test`）で検証し、
    `infra/policy/*.rego` が想定どおり追従できるか確認する。
  - 実際に「Policy as Code をオプトアウトしたい」という下流ニーズが具体化したら、上記の
    `hashFiles` ガード追加を別 issue として起票し実装する。
