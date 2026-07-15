# ADR-0012: CI reusable workflow は本リポジトリ内に置き、リリースタグで参照する

- **Status:** Accepted
- **Date:** 2026-07-14
- **Deciders:** itouhi
- **Related:** #295、[Epic #300](https://github.com/iwata-jawsug-jp/devcon/issues/300)、#153（指摘7）、
  [ADR-0010](0010-adopt-copier-for-scaffold-cli.md)・[ADR-0011](0011-scaffold-template-in-place.md)
  （同じ「本リポジトリ自身が配布物」という設計方針の延長）

## Context

`ci.yml` と `ci-sandbox.yml` は本来同じ品質ゲートを実行するはずだが、実際に diff を取ると
DESIGN.md lint・バンドル予算・Lighthouse CI・Playwright E2E・`scripts` ジョブ・`scaffold` ジョブが
`ci-sandbox.yml` から丸ごと欠落しており、tflint/checkov/trivy のバージョン pin も一致していない
（#153 指摘7で既に問題視されていた drift が実際に拡大していた）。#294 でテンプレート化した
モノレポを下流の複数プロジェクトが消費するようになると、各プロジェクトがワークフローを
コピーで持つ限り同じ drift が指数的に増える。

検討した論点は2つ。

### 論点1: reusable workflow の置き場所

- **本リポジトリ内 `.github/workflows/`**: `uses: iwata-jawsug-jp/devcon/.github/workflows/
reusable-ci.yml@<ref>` の形で他リポジトリから参照できる（GitHub Actions は public リポジトリ
  であればこれをサポートしており、追加のリポジトリ作成は不要）。
- **専用 `.github` リポジトリ**（GitHub の "community health files" 的な特別リポジトリ、または
  単なる `ci-shared`/`workflows` という名前の別リポジトリ）: ワークフロー専用の独立したリリース
  サイクルを持てるが、[ADR-0011](0011-scaffold-template-in-place.md) で確立した「本リポジトリ
  自身が常に動くテンプレートであり続ける（ドッグフーディング）」という方針と矛盾する。
  ci.yml 自身がそのワークフローの実利用者になれないため、reusable workflow の劣化に devcon
  自身の CI が気付けなくなる。

### 論点2: バージョニング方針

- **タグ参照**（`@v0.3.8` のような、既存の `docs/release.md` の `v*` セマンティック
  バージョンタグをそのまま使う）: このリポジトリは GitHub Release のたびに `v*` タグを打つ運用が
  既に確立している（`publish.yml` のトリガーでもある）。reusable workflow 専用の別バージョン体系を
  新設する必要がない。
- **ブランチ参照**（`@main`）: 下流は常に最新の変更を受けるため予測不能な breaking change を
  食らうリスクがある。GitHub Actions のセキュリティ観点でも、taggable な参照より可変な `main`
  参照は推奨されない（サプライチェーン的に、コミットの中身がタグより追跡しにくい）。

### 論点3（検討中に判明した新たなリスク）: check 名への影響

`workflow_call` の実際の挙動を、本リポジトリの使い捨てブランチで実地検証した
（`outer-job-name: uses: ./...` → `inner-job-name` というジョブを持つ reusable workflow を
呼び出したところ、実際の check run 名は **`outer-job-name / inner-job-name`** になった。
`gh api repos/<owner>/<repo>/commits/<sha>/check-runs` で確認済み）。

これは重大な帰結を持つ: 現在 `main` に設定している `main-ci-required` ルールセット
（[`docs/infrastructure.md`](../infrastructure.md)「ブランチ保護」参照）の
`required_status_checks` は `changes` / `backend` / `frontend` / `infra` / `scripts` という
**裸のジョブ名**を要求している。`ci.yml` を reusable workflow 呼び出しに置き換えると、これらの
check 名は必然的に `<呼び出し側ジョブ名> / <内側ジョブ名>` の形に変わり、既存のルールセットの
必須チェックと一致しなくなる。**何も対策せずにマージすると、`main` へのすべての PR が「必須
チェックが永遠に現れない」状態でマージ不能になる。**

## Decision

1. **reusable workflow は本リポジトリ内 `.github/workflows/reusable-ci.yml` に置く。** 専用
   リポジトリへの切り出しは行わない。ADR-0011 と同じ理由（ドッグフーディング、単一の
   保守対象）。
2. **バージョン参照は既存の `v*` リリースタグを使う。** 新しいバージョン体系を作らず、
   `docs/release.md` の既存リリースフローに乗せる。
   **（実装中に判明・訂正）参照先は `iwata-jawsug-jp/devcon` ではなく公開ミラー
   `iwata-jawsug-jp/devcon` にする。** devcon は非公開リポジトリのため、他リポジトリから
   `workflow_call` すると GitHub 側の Actions アクセス制御（`repos/<owner>/<repo>/actions/
permissions/access`）に阻まれて起動不能（startup failure）になる。この設定を `none` から
   変更すること自体は可能だが、リポジトリのセキュリティ設定変更であり、既存の「開発用（非公開）
   / 公開用（`iwata-jawsug-jp/devcon`）」の2リポジトリ運用（`docs/release.md`）とも整合しない。
   公開ミラーは元々「fork した人が消費する対象」として設計されているため、reusable workflow の
   消費もそこを正とするのが自然。実際に `v0.3.9` を公開後、`itouhi/devcon-test` から
   `uses: iwata-jawsug-jp/devcon/.github/workflows/reusable-backend.yml@v0.3.9` で呼び出し、
   green になることを確認した（devcon-test#22）。`copier.yml` で生成したプロジェクトの CI も
   この形（公開ミラー参照）で揃える（#294 のテンプレートを reusable workflow 参照前提に
   更新するのは #295 の完了条件）。
3. **`main-ci-required` ルールセットの必須チェック名を、reusable workflow 移行と同時に
   更新する。** 呼び出し側のジョブ名を `changes` / `backend` / `frontend` / `infra` / `scripts`
   と**まったく同じ名前のまま**にはできない（`workflow_call` の1ジョブが内部ジョブへ展開される
   ため、check 名は必ず `<呼び出し側ジョブ名> / <内側ジョブ名>` になり、1:1 の名前一致は構造上
   不可能）。呼び出し側ジョブ名は現行のまま（`changes`/`backend`/`frontend`/`infra`/`scripts`/
   `scaffold`）維持し、各 reusable workflow 内の唯一のジョブを一律 `check` と名付けることで、
   check 名を `backend / check` のように予測可能かつ最小限の変更で揃える。**ルールセットの
   更新は、コード変更をマージするタイミングで人手の確認を挟んで同時に行う**（GitHub 側の設定
   変更のため、Claude Code からの自動適用は行わず、コマンドを提示してユーザーの実行判断を
   仰ぐ運用とする）。
4. **各エリア（backend/frontend/infra/scripts/scaffold）の実行ステップを、エリアごとに1つの
   reusable workflow ファイルへ切り出す**（`reusable-backend.yml` 等）。path-filter による
   「実行するかどうか」の判断（`changes` ジョブの出力・エリア別スイッチ）は reusable workflow
   の中に含めず、呼び出し側（`ci.yml`/`ci-sandbox.yml`）が計算するが、**呼び出しジョブ自体に
   `if:` を付けて丸ごとスキップさせることはしない**（次項参照）。これにより:
   - `ci.yml` は現行どおり `changes` ジョブ（`reusable-changes.yml`）の出力を参照する。
   - `ci-sandbox.yml` は `changes` を呼ばず、各エリアの reusable workflow を無条件に呼ぶ
     （現行の「新規ブランチでの diff エッジケース回避のためパスフィルタなし」という意図した
     挙動を、input フラグを増やさずそのまま再現できる）。
   - 「同一の reusable workflow を呼ぶ」という完了条件は、各エリアの**実行ステップ**（今回
     drift していた実体）が単一ソースになることで満たす。「いつ実行するか」の判断はそもそも
     `ci.yml` と `ci-sandbox.yml` で意図的に異なる（設計上の差異であって drift ではない）ため、
     無理に1つに統合しない。
5. **（実装中に発見・修正）呼び出しジョブへの `if:` は check 名をさらに壊す。** 当初は
   `ci.yml` 側の `backend:` ジョブに `if: needs.changes.outputs.backend == 'true' && ...` を
   付けたまま `uses:` する設計だったが、実際に PR #462/#463（該当エリア変更なし＝スキップ
   対象）で検証したところ、スキップされたジョブは `backend / check` ではなく**素の
   `backend`**（`/ check` サフィックス無し）という別の check 名で報告されることが判明した
   （`gh api repos/.../commits/<sha>/check-runs` で確認）。実行時は `backend / check`、
   スキップ時は `backend` と、状態によって check 名そのものが変わってしまうため、
   `main-ci-required` に `backend / check` を登録すると、その エリアが スキップされる PR
   （＝そのエリアを変更しない大多数の PR）が永久にマージ不能になる（実際に PR #462/#463 で
   発生させてしまった）。
   **修正:** 呼び出しジョブ側の `if:` を撤廃し、常に `uses:` する。スキップの可否は
   reusable workflow への `with: should_run: <条件式>` 入力として渡し、reusable workflow
   内部の唯一のジョブ（`check`）に `if: inputs.should_run` を付ける。これにより呼び出しは
   常に発生する（＝ check 名は常に `backend / check` のまま安定する）が、`should_run` が
   `false` なら内部ジョブが `skipped` 状態で完了する。使い捨てブランチで
   `outer-job / inner-job`（内部 `if: inputs.should_run == false`）を実地検証し、
   `outer-job / inner-job: completed/skipped` という一貫した check 名になることを確認済み。

## Consequences

- **良い面:**
  - `ci.yml` と `ci-sandbox.yml` が同一の reusable workflow を呼ぶ構造になり、#153 指摘7の drift が
    構造的に発生しなくなる（完了条件を満たす）。
  - 下流（copier で生成したプロジェクト、devcon-test 等）が同じ品質ゲートをタグ参照で再利用でき、
    devcon 側の改善が `copier update` や単純な参照バージョン変更で伝播する。
  - 既存のリリースタグ運用にそのまま乗るため、新しい配布・バージョン管理の仕組みを増やさない。
- **トレードオフ・新たに生じる負担:**
  - **`main-ci-required` ルールセットの更新が実装 PR のマージと不可分になる。** 順序を誤ると
    （コードだけ先にマージしてルールセット更新を忘れると）`main` への全 PR がマージ不能になる、
    または（ルールセットだけ先に新チェック名へ更新して古い ci.yml のままだと）必須チェックが
    一切満たされない状態になる。実装 PR のマージ直後にルールセット更新コマンドを実行する運用
    手順を `docs/infrastructure.md` に明記する。
  - 下流リポジトリは `v*` タグの更新を追従する必要がある。放置すると古いバージョンの品質ゲートに
    固定され続ける（`copier update` の対象外なので、reusable workflow のバージョンだけは別途
    追従を意識する必要がある — #298「テンプレート更新の下流追従」の一部として扱う）。
  - reusable workflow 化によりログの階層が1段深くなる（Actions タブで `ci-backend` を展開しないと
    `check` の中身が見えない）。可読性はやや下がるが、drift を構造的に防げる利益の方が大きいと
    判断。
  - **（実装中に発見・修正）org レベルルールセットとの衝突。** `docs/org-rulesets.md` で
    `iwata-jawsug-jp` org 全体に適用した `org-baseline`（PR 必須・force-push 禁止）が、
    `iwata-jawsug-jp/devcon` への `publish.yml` の意図的な直接 push（deploy key 経由、1リリース
    = 1スナップショットコミット、`docs/release.md`）を `GH013: Repository rule violations` で
    ブロックしてしまい、v0.3.9 の公開が一度失敗した。`org-baseline` の
    `conditions.repository_name.exclude` に `devcon` を追加して解消した。**教訓:** 「PR 必須・
    直push禁止」のような組織一律ポリシーを適用する前に、対象 org 配下の各リポジトリが持つ
    既存の自動化（デプロイキーによる直接 push 等）を洗い出す必要がある。
- **再検討トリガー:** タグ参照での運用が下流の追従負担として重すぎると分かった場合、または
  reusable workflow の変更頻度がリリース頻度より著しく高く `v*` タグでは追従が遅すぎると分かった
  場合、専用の軽量バージョンタグ（`workflows-v1` のような独立した体系）を再検討する。
