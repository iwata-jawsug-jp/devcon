# ADR-0011: スキャフォールドテンプレートは本リポジトリ自身とし、専用リポジトリへ切り出さない

- **Status:** Accepted
- **Date:** 2026-07-14
- **Deciders:** itouhi
- **Related:** #294、[ADR-0010](0010-adopt-copier-for-scaffold-cli.md)（copier 採用）、
  [Epic #300](https://github.com/iwata-jawsug-jp/devcon/issues/300)、#436、#438

## Context

#294 の検討項目「テンプレートリポジトリの置き場所（本リポジトリを直接テンプレート化するか、
`template` 専用リポジトリへ切り出すか）の判断」に対応する。

判断材料として、次の2つの既存事実を確認した。

1. **第2消費者実証が既に「本体の fork」として動いている。** `itouhi/devcon-test`（v0.3.3 の
   fork）は専用テンプレートリポジトリではなく devcon 自身を直接 fork したもので、この
   実運用を通じて #436（S3 バケット名・Cognito ドメイン名のグローバル名前空間衝突）・#438
   （OAuth scope 追加時の3点セット漏れ）という、単一テナント（devcon 自身のデプロイ）
   だけでは顕在化しない不具合が2件見つかり、devcon 本体に修正が入った
   （`local.global_name_prefix` 追加、`check_oauth_scopes.py` の静的ゲート追加）。
2. **「同一リポジトリから、除外リスト＋文字列置換で派生物を作る」仕組みが既に実装・運用されて
   いる。** `tools/script/publish-to-public.sh` は `iwata-jawsug-jp/devcon` の指定 ref から
   `EXCLUDES` 配列で内部限定ファイル（`docs/proposal/`、`docs/release.md`、issue テンプレート
   の一部等）を除いたうえで `devcon → devcon` / `iwata-jawsug-jp/devcon →
iwata-jawsug-jp/devcon` の文字列置換を行い、公開ミラー（`iwata-jawsug-jp/devcon`）へ
   スナップショット公開している。copier の in-place テンプレート化に必要な仕組み（除外リスト
   ＋変数置換）と構造的に同一の前例が、既に別目的（公開ミラー）で1年近く運用されている。

## Decision

**devcon 自身を copier テンプレートのソースとする。専用の `template` リポジトリは
作らない。** copier は Git リポジトリを直接ソースとして参照できるため
（`copier copy gh:iwata-jawsug-jp/devcon <target-dir>`）、技術的な障壁はない。

却下理由（専用テンプレートリポジトリへの切り出し案）:

- [ADR-0010](0010-adopt-copier-for-scaffold-cli.md) で copier を選んだ決め手は `copier update`
  による下流追従（#298）だった。この追従が意味を持つのは、生成元と「今も動いている本体」が
  同一である場合に限る。別リポジトリに切り出すと、devcon 本体に入った修正（#436・#438
  のような、実際の fork 運用で初めて顕在化する不具合）をテンプレートリポジトリへ都度手動移植
  する運用が必要になり、#153 が指摘した「fork してコピーして手で調整する」問題をテンプレート
  の保守側で再現してしまう。
- devcon-test という実運用の第2消費者が既に「devcon 自身の fork」として存在する。
  専用テンプレートリポジトリを新設すると、devcon-test はどちらの流儀の生成物なのか位置づけが
  曖昧になる。
- `publish-to-public.sh` の EXCLUDES ＋文字列置換の設計をそのまま下敷きにできるため、専用
  リポジトリを新設して一から設計するより実装コストが低い。

生成対象から除く必要があるコンテンツ（copier の `_exclude` / Jinja 条件分岐で対応。具体的な
除外リストの確定は変数設計フェーズで行う）:

- リリース配管そのもの: `.github/workflows/publish.yml`、`tools/script/publish-to-public.sh`、
  `docs/release.md`
- 開発用リポジトリの内部運用ドキュメント: `docs/proposal/`、`.kiro/steering/`（`product.md` 等
  は devcon 固有の記述を含むため、ひな形化するか除外するか要検討）
- devcon 自身の意思決定履歴: `docs/adr/000*`・`docs/adr/0010`・本 ADR
  （issue 番号など devcon 固有の文脈を含む。新規プロジェクトに構造の参考例として残すか
  除外するかは変数設計フェーズで判断）
- `CHANGELOG.md`（新規プロジェクトは空から始める）
- golden-path-verify 系（`docs/proposal/template-verification-environment-proposal.md` の通り
  開発用リポジトリ自己検証専用。`publish-to-public.sh` が公開ミラーからも除外している前例と
  同じ扱いでよいか検討）

## Consequences

- **良い面:**
  - `copier update` が実際に機能する構図になる（生成元が本体そのものなので、本体の改善が
    そのまま追従対象になる）。
  - devcon-test という既存の実証運用との整合が取れる。
  - `publish-to-public.sh` の前例を再利用でき、除外リスト・置換ロジックの設計コストが下がる。
  - devcon 自身が常に「動くテンプレート」であり続ける（ドッグフーディングにより、
    テンプレートだけが陳腐化する事態を防げる）。
- **トレードオフ・新たに生じる負担:**
  - `_exclude` / 条件分岐リストのメンテナンス負担が生じる。devcon にプロジェクト固有
    ファイルが増えるたびに、テンプレート除外リストの更新を忘れないようにする必要がある。
    `publish-to-public.sh` の `EXCLUDES` で同種の負担は既に実績があるが、2つの除外リスト
    （公開ミラー用・スキャフォールド用）が二重管理になる可能性があり、将来的に共通化を検討
    する余地がある。
  - `items` CRUD・authn-authz といった「本物のドメイン実装」がテンプレートに混入する。新規
    プロジェクトにとってこれを土台として残すか取り除くかは、変数設計フェーズの検討課題として
    持ち越す。
  - 生成元 ref の指定が要る。`main` ブランチを常に生成元にすると、作業中の一時的な壊れた状態を
    生成してしまうリスクがある。タグ運用（リリースごとに生成元を固定する）が必要かどうかは、
    生成物検証 CI の設計フェーズで詰める。
- **再検討トリガー:** `_exclude` リストの運用コストが実装を通じて過大と分かった場合、または
  生成物に devcon 固有のドメインロジック（`items` 等）が混入することが実際に第三者の
  混乱を招くと判明した場合、専用テンプレートリポジトリへの切り出しを再検討する。
