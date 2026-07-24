# ADR-0025: `cd-sandbox-cycle.yml` の apply 前に「state が空か」の共有 state ガードを入れる

- **Status:** Accepted
- **Date:** 2026-07-24
- **Deciders:** Itou Hideki
- **Related:** #631（問題2）、[docs/sandbox.md](../sandbox.md) 週次エフェメラルサイクル、
  [ADR-0023](0023-cd-app-deploy-reusable-workflow-and-tfvars-materialize.md)

## Context

`cd-sandbox-cycle.yml`（週次エフェメラルサイクル、#376 PR④）は `apply → deploy →
live-smoke → teardown` を 1 回の実行で完走させる。`TF_ENV=sandbox` は
`cd-infra-sandbox.yml`（`sandbox/*` ブランチでの手動検証）と単一の Terraform state を
共有しており、`docs/sandbox.md` は「実行前に必ず、他に sandbox を使っていないか確認する
こと」と注意書きしているが、これは人間が覚えているだけの運用であり機械的なガードが
無かった。

#631 の実地検証で、長期稼働の sandbox 環境が既に teardown 済みであることに気づかず
`cd-app-sandbox.yml` を実行し、`preflight` が誤って `configured=true` と判定して分かり
にくいエラーで失敗する、という事故が発生した（この問題自体は PR #632 で解決済み:
`SANDBOX_*` リポジトリ変数を destroy 後に `--clear` で削除できるようにした）。同 issue の
問題2として指摘されたのは逆方向のリスクである: `cd-sandbox-cycle.yml` の `apply` が、
人間が `sandbox/*` で手動検証中の環境や、teardown まで完走しなかった前回実行の残骸を
巻き込んで上書きし、その後の `teardown` で予告なく破棄してしまう可能性。

## Decision

`apply` ジョブの `terraform init` の直後、実際の `terraform apply` の前に
`terraform state list` を実行し、**state が空かどうか**で判定する:

- **エラー:** そのままジョブを失敗させる。
- **空でない（resource が 1 件以上ある）:** 既に誰か（人間の手動検証、または完走しなかった
  前回実行）によって state に resource が入っていることを意味する。`confirm_shared_state`
  という `workflow_dispatch` の文字列 input が正確に `proceed` でない限りジョブを失敗させ、
  「他に誰も sandbox を使っていないか確認してから再実行する」よう促すメッセージを出す。
  `cd-infra-sandbox.yml` の `confirm_destroy`（「`workflow_dispatch` というボタンを押した
  だけでは実行されない」ためのタイプ入力）と同じパターンを踏襲する。
- **空:** ゼロからの通常のエフェメラル実行として想定どおりの経路。何もせず先へ進む。

### 判定方式の変遷（sandbox 実機検証で 2 段階の欠陥が見つかった）

最初の実装は「`terraform plan -detailed-exitcode` の終了コードが `0`（変更なし）＝
state が設定ファイルと完全に一致＝既にフル適用済み」という判定だったが、実際に
sandbox で通しで検証したところ、**2 つの欠陥**が見つかり、最終的に上記の
「state が空か」という判定に置き換えた。机上のレビューや YAML 構文チェックだけでは
どちらも検出できず、実機検証で初めて判明したものである。

1. **`hashicorp/setup-terraform@v4` のラッパーが常に exit code 0 を返す問題。**
   同 Action は既定で `terraform` 本体をラッパースクリプトで包み、標準出力/標準エラーを
   `steps.*.outputs.stdout` 等に取り込めるようにするが、**そのラッパー自体は常に
   exit code 0 を返す**ため、`-detailed-exitcode` の実際の終了コード（0/1/2）が
   呼び出し元シェルの `$?` に伝わらない。これにより「変更なし」判定が常に真になり、
   **空 state からの通常実行を毎回誤ってブロック**していた（1 回目の実機検証で再現）。
   `Set up Terraform` ステップに `terraform_wrapper: false` を追加してラッパーを無効化し、
   終了コードが正しく `$?` に伝わるようにして解消した。
2. **「plan に差分がない」は「誰かが使用中」の判定として機能しない、より本質的な欠陥。**
   ラッパー修正後の再検証で、今度は逆方向の問題が見つかった: `infra/api.tf` の
   `data.external.api_current_image`（#374）は「ECS が実際に稼働させている image タグを
   都度読みに行き、infra だけの apply で `:bootstrap` プレースホルダーに巻き戻さない」
   ための仕組みだが、これは裏を返すと **`app-deploy`（`cd-app-sandbox.yml` や本ワークフロー
   自身の `app-deploy` ジョブ）で実際にデプロイされた環境は、次の `terraform plan` で
   ほぼ必ずタスク定義の diff が出る**ことを意味する。つまり「plan が無変更」という条件は、
   本当に守りたい対象（実際に使われている環境）ではまず成立せず、**ガードが実際には
   ほとんど発火しない false negative** になっていた（安全機構として致命的）。
   これを踏まえ、判定を「state に resource が 1 件でもあるか」に変更した。これは
   「完走した previous run と、途中で失敗した previous run を区別できない」という
   粗さと引き換えに、本来検出したい「誰かが使用中」を確実に捉える。false positive
   （誤ってブロックする）は人間の確認 30 秒で済むが、false negative（誤って見逃す）は
   他人の環境を破棄しうる、という非対称性を踏まえた判断。

**このガードだけでは不十分だった別の欠陥（同時に修正）:** `teardown` ジョブは
`needs: smoke-test` に `if: always()` を付けており、これは「`apply`/`app-deploy`/
`smoke-test` が失敗・スキップになっても関係なく実行される」ことを意味する。つまり
`apply` がガードで意図的に失敗しても、`teardown` は**別ジョブとして自分で AWS 認証を
やり直し、独立に `terraform destroy` を実行してしまう**。これはガードが防ぎたい事故
そのもの（共有 state を無警告で破棄する）を、ガードを回避する形で再現してしまう欠陥
だった。対策として `apply` ジョブに `applied` output（実際に `terraform apply` まで
到達した場合のみ `true`）を追加し、`teardown` の `if` 条件に
`needs.apply.outputs.applied == 'true'` を追加した。ガードが止めた場合はもちろん、
OIDC の `ref` 制約（`docs/sandbox.md`）等どんな理由であれ `apply` が実際の
`terraform apply` に到達する前に失敗した場合は、`teardown` は実行されず `skipped` になる。

却下案:

- **destroy 側にガードを入れる案**（例: 「このジョブが作った resource だけを個別に
  destroy する」）は、Terraform の state 管理の外で resource 単位の所有権を追跡する仕組みが
  新たに必要になり複雑すぎるため不採用。
- **`terraform plan -detailed-exitcode` の終了コードで判定する案**は当初の実装だったが、
  上記のとおり sandbox 実機検証で「実際に使われている環境をほぼ検出できない」ことが
  判明したため不採用（`data.external.api_current_image` の設計と根本的に相性が悪い）。
- **`schedule` トリガーの追加と同時に対応する案**は、`schedule` 自体がまだ導入されておらず
  （docs/sandbox.md 記載の理由）、ガード自体は手動実行時点でも有効な安全策のため、
  `schedule` 導入を待たずに先に入れる。

## Consequences

- 良い面: 「既に埋まっている共有 state を無自覚に apply → destroy してしまう」事故を機械的に
  防げる。誤操作防止のタイプ入力パターンが `cd-infra-sandbox.yml` と `cd-sandbox-cycle.yml`
  の両方で一貫する。
- 悪い面・負担: 途中で失敗した前回実行が resource を一部だけ残しているケースも一律で
  ブロックされる（`confirm_shared_state=proceed` での再実行、または
  `cd-infra-sandbox.yml` の手動 destroy による事前クリーンアップが必要）。
  `confirm_shared_state` を知らずに実行した利用者は、最初の 1 回は必ず停止で学習する
  ことになる（意図した挙動）。
- 再検討トリガー: `schedule`（無人の週次自動実行）を導入する場合、`confirm_shared_state`
  という人間の入力を前提にしたこのガードはそのままでは機能しない。無人実行時は
  「共有 state が埋まっていたら silently skip して issue を起票する」等の代替設計に
  切り替える必要があり、その時点で本 ADR を見直す。
