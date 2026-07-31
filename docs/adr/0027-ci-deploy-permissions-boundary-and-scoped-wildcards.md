# ADR-0027: ci_deploy は「許可の境界による昇格封じ」を最優先し、identity policy はスコープ済み文のみワイルドカード化する

- **Status:** Accepted
- **Date:** 2026-07-25
- **Deciders:** Itou Hideki
- **Audience:** publish, generate
- **Related:** #45（PowerUserAccess → 最小権限、本 ADR が部分的に修正する元の判断）、
  #651（権限ギャップ修正）、#652（マネージドポリシー枠 9/10）、
  [PR #653](https://github.com/iwata-jawsug-jp/devcon/pull/653) /
  docs/proposal/ci-deploy-iam-scoping-strategy-proposal.md（4案の比較検討、本 ADR の根拠）、
  [ADR-0017](0017-policy-as-code-conftest.md)（Policy as Code）、
  [ADR-0019](0019-policy-as-code-downstream-distribution.md)（下流配布）

## Context

#45 で `ci_deploy` ロールを PowerUserAccess から最小権限（action / リソース ARN /
リージョンの3軸でスコープした Allow の個別列挙）へ移行した。その判断自体は妥当だったが、
運用を続けた結果2つの構造的な問題が表面化し、さらに監査の過程で3つ目の問題が見つかった。

**課題A: 権限ギャップの後追いが構造的コストになっている。**
Allow の個別列挙は「Terraform プロバイダが plan / apply / refresh / destroy の各経路で
実際にどの API を呼ぶか」を全て事前に当てることを要求する。当たらなかった分は
実 AWS の apply / destroy でしか顕在化せず（CI の plan では踏まない）、
#258 / #338 / #437 / #587 / #600 / #631 / #640 と繰り返し後追いが発生している。
#651 で見つかった `ec2:ModifySecurityGroupRules` は、sandbox が毎回まっさらから作り直す
ため Create 経路しか通っておらず、**まだ一度も顕在化していない**潜在ギャップだった。
update / destroy 経路のギャップは検証設計上そもそも踏みにくく、この構造は
Allow 列挙方式である限り残り続ける。

**課題B: マネージドポリシー枠が 9/10。**
`terraform.tfstate` から実測したところ、サイズは最大でも 3,917/6,144 字（64%）で余裕がある
一方、**個数が先に効いている**。クォータは Service Quotas で 25 まで引き上げ可能だが、
本リポジトリは copier scaffold（#294、ADR-0010/0011）で配布されるテンプレートであり、
生成先アカウントごとに手動申請が必要になると「fresh clone で `infra/bootstrap` が
そのまま apply できる」という前提が壊れる。

**課題C: 最小権限設計そのものに権限昇格経路が開いている（提案書の検討中に発見）。**
`iam-ci-deploy-iam.tf` の `ManageProjectRoles` 文は `arn:aws:iam::*:role/${var.project}-*`
に対して `iam:CreateRole` / `iam:AttachRolePolicy` / `iam:PutRolePolicy` を**条件なしで**
許可している。アタッチできるポリシーに制約が無く、しかも `locals.tf` の
`name_prefix = "${var.project}-${var.resource_name_suffix}"` により
**`ci_deploy` 自身のロール名（`${var.project}-<suffix>-ci-deploy`）がこの ARN パターンに
マッチする**。したがって最短経路は `AttachRolePolicy AdministratorAccess` を
**自分自身に付ける1ステップ**で成立する。同じ理由で `${var.project}-*-ci-plan` や
`${var.project}-*-agent-mcp` も改変でき、`iam-agent-mcp.tf` の `agent_mcp_guardrails` の
Deny 文を外すこともできる。

新規ロールを経由する経路（`CreateRole`（trust: ecs-tasks）→
`AttachRolePolicy AdministratorAccess` → `PassRole` → `RegisterTaskDefinition` + `RunTask`）
も同様に成立する。`iam:PassRole` は `iam:PassedToService` で `ecs-tasks.amazonaws.com` /
`lambda.amazonaws.com` に絞られているが、**ECS タスクとして管理者ロールを実行できれば
十分**なのでこの条件は経路を塞がない。つまり現状は「`ci_deploy` に付与した権限」より
「`ci_deploy` が到達しうる権限」の方が広い。

課題A への素朴な対処は「PowerUserAccess に戻す」だが、それは #45 の判断を無に帰すうえ、
課題C をさらに悪化させる。一方で Allow 列挙を続ければ課題A は永続する。
この対立を整理するため、提案書で4案（PowerUserAccess + α / PowerUserAccess + Deny
ガードレール / スコープ済み文のみワイルドカード化 / 許可の境界）を13評価軸で比較した。

## Decision

**単一の案を選ぶのではなく、優先度の異なる3層として実施する。**

### 第1層（最優先・identity policy の方針と独立に着手する）: 作成ロールへの許可の境界の強制

課題C に対処できるのはこれだけであり、AWS ユーザーガイド
「Delegating responsibility to others using permissions boundaries」に明記された
標準パターンをなぞるだけなので、他の判断を待たずに着手する。

`iam-ci-deploy-iam.tf` の `ManageProjectRoles` を分割し、`iam:PermissionsBoundary`
条件キーによって**指定の境界ポリシーを付けた場合にのみ**ロール作成・ポリシー操作を
許可する。併せて境界の取り外し（`iam:DeleteRolePermissionsBoundary`）と、
境界ポリシー自体の書き換え（`iam:CreatePolicyVersion` 等）を明示 Deny する。

これにより、自己 Attach 経路は「境界の付いていない `ci_deploy` 自身（および `ci_plan` /
`agent-mcp`）に対する `AttachRolePolicy`」が条件を満たさず失敗する。新規ロール経由の
経路は、手順2（`AttachRolePolicy AdministratorAccess`）ではなく手順1（`CreateRole`）の
時点で失敗する — 境界を付けずにロールを作れないため。仮に作られたロールに管理者
ポリシーを付けても、境界との積集合で実効権限は上がらない。

同時に `DenyAssumeRole`（多段 assume によるピボット封じ）を入れる。Deny 文なので
`iam_wildcard.rego` に抵触せず、`iam-agent-mcp.tf` の `agent_mcp_guardrails` と同型で
実績もある。

**第1層の実装は identity policy だけでは閉じない。** 次の3つをセットで行う。

1. **境界ポリシー本体の追加**（`infra/bootstrap`）。
2. **app 層（`infra/*.tf`）の変更。** ECS タスクロール / タスク実行ロール（`shared.tf`）と
   worker Lambda ロール（`worker.tf`）に `permissions_boundary` を設定する。これを欠くと
   第1層適用後の app 層 apply が `CreateRole` で止まる。
3. **既存環境の移行順序の設計。** `iam:PermissionsBoundary` 条件キーは
   `AttachRolePolicy` / `PutRolePolicy` / `DetachRolePolicy` に対しては
   **対象ロールに現在付いている境界**を評価するため、境界未設定の既存ロールに対する
   更新・削除系が deny になる（AWS の委譲パターン例が Detach / Delete も条件付き文に
   含めているのと同じ理屈）。`PutRolePermissionsBoundary` が先に通る順序で移行する
   必要があり、fresh な sandbox の新規作成だけを検証してもこの窓は踏まない。

併せて `ManageProjectRoles` のリソース ARN のアカウント部（現状 `arn:aws:iam::*:role/...`）
を自アカウント ID に絞る。IAM 呼び出しは呼び出し元アカウント内で完結するため実害は薄いが、
第1層で同じ文を書き直す好機である。

### 第2層: identity policy は「スコープ済み文のみ」action をワイルドカード化する

**リソース ARN が `${var.project}-*` にスコープされている文だけ**、action を
サービスレベルのワイルドカードに緩める（例: `ecr:*` on
`arn:aws:ecr:*:*:repository/${var.project}-*`、`s3:*` on `arn:aws:s3:::${var.project}-*`。
既存の `aws:RequestedRegion` 条件は維持し、元から無い文に新たに足すこともしない）。
以下は**緩めない**。

- `Resource = "*"` の文 — `Elb` / `ApplicationAutoScaling` / `Cognito` / `CloudFront` /
  `Ec2Networking` / `EcrAuth` / `LambdaEventSourceMappings` / 各種 Describe 系 /
  `ServiceLinkedRoles`。
- リソース ARN は具体的だが**プロジェクト所有でない**リソースを指す文 — KMS 系
  （`S3DefaultKmsKey` / RDS・Secrets Manager のデフォルトキー）。`${var.project}-*` の
  前方一致による囲い込みが効かないため、ARN スコープ済みでも緩和対象に含めない。
- IAM 系（第1層で条件付き文に作り替える）と state アクセス（bootstrap が管理する
  state バケットを指す）。

後追いの実例のうち #258 / #600 と #640 の一部（`lambda:ListVersionsByFunction`）は
「スコープ済みリソースに対するプロバイダの予測外の呼び出し」であり、action 軸だけを
緩めれば消える。一方 **#587 の本体（`S3DefaultKmsKey` の `kms:DescribeKey` /
`GenerateDataKey`）と #640 の残り（`LambdaEventSourceMappings` は `Resource = "*"`、
ENI クリーンアップは EC2）は緩和対象外の文なので消えない。** 守りの主力である
リソース ARN 軸とリージョン軸は完全に維持されるため、「他リージョン・他リソースへの
横展開」は依然として塞がったままになる。

この前提として `infra/policy/iam_wildcard.rego` を「Allow + ワイルドカード action は
一律禁止」から緩める。現行ルールは「スコープ済みワイルドカード」と「無制限
ワイルドカード」を区別できておらず、この緩和は実態に即した改善でもある。ただし
許容条件は以下のとおりとする。

- **`Resource` が `*` でないこと**（必須）。
- **リージョン条件は `region_condition.rego` の対象サービス**（ec2 / ecs / ecr / rds /
  logs / elasticloadbalancing / application-autoscaling）**に限って必須**とする。
  「`Resource != "*"` かつ一律にリージョン条件必須」と書いてはならない — 軸2 が効いていて
  なお**意図的にリージョン条件を持たない**文が2つあり（`S3ProjectBuckets`: `aws s3 sync` が
  グローバル / us-east-1 エンドポイント経由になりうるため #45、`CloudWatchDashboard`:
  ダッシュボード ARN にリージョンセグメントが無いため #258）、その条件では
  「緩和対象なのに rego に弾かれる」という自己矛盾になる。
- 緩和は `ecr:*` のような**サービスレベルのワイルドカードに限り**、bare の
  `Action: "*"` は `Resource` がスコープ済みでも許容しない。現行の
  `is_wildcard_action` は `"*"` と `"<service>:*"` を区別していないので、実装時に分ける。

また、許可の境界ポリシーは `iam_wildcard.rego` の**対象外**とする。境界は権限の
付与ではなく上限の設定であり、`Action: "*"` を含むことがその性質上正常だからである。
ただし plan JSON 上は境界ポリシーも通常の `aws_iam_policy` であり型では区別が付かない
ため、除外は**ポリシー名の接尾辞 `-boundary`** で識別する。規約を rego のコメントに
明記し、`iam_wildcard_test.rego` に「名前が合致しない `Action: "*"` は従来どおり deny
される」ケースを追加して、除外が実質的な素通し口にならないようにする。

### 第3層: `ci_deploy` 自身への許可の境界 — 再評価の結果、**採用しない**（2026-07-25 追記）

第2層を入れた時点でリージョン軸は identity policy 側で既に効いているため、
`ci_deploy` 自身に境界を張る目的は「identity policy を将来どう変更しても
リージョン上限だけは動かない」という二重化に絞られる。価値はあるが緊急性は無いため
当初は「現時点では採用せず、第1・2層の完了後に費用対効果を再評価する」とした。

**第1・2層（#656 / #658）と付随作業（#651 / #657 / #652）の完了を受けて再評価し、
採用しないことを決めた。** 理由は3つある。

**1. 天井が薄い。** `ci_deploy` が正当に必要とするものを列挙すると、境界は
`s3:*`（`aws s3 sync` がグローバル / us-east-1 エンドポイント経由になりうる、#45）、
`cloudfront:*`（グローバルサービス）、`iam:*`（`CreateRole` / `AttachRolePolicy` /
`PassRole` / SLR 作成）をいずれもグローバルに許可せざるを得ない。結果として天井が実際に
足すのは「他リージョンの遮断」と「organizations / account の遮断」程度で、**最も価値の
高い攻撃対象（全 S3 バケット、CloudFront 設定、IAM）はカーブアウトで開いたまま**になる。
これは案2（PowerUserAccess + Deny ガードレール）を却下したときと同型の結論である。

**2. 守ろうとしていたドリフトの大半は、より安い機構が既に担っている。** 第2層で
リージョン軸は identity policy に入り、#657 で `infra/bootstrap` も `conftest test` の
対象になった。identity policy を緩める変更は PR 時点で落ちる — 境界起因の deny より
原因が分かりやすく、実 apply を待つ必要もない。

**3. 残る穴は、境界より安く塞げる。** ただし静的ゲートには実在する抜けがある:
`infra/policy/*.rego` は `aws_iam_policy` / `aws_iam_role_policy` の**文書**しか見て
おらず、`aws_iam_role_policy_attachment` で AWS マネージドポリシー
（`PowerUserAccess` / `AdministratorAccess`）を足す経路は全ブロッキングゲートを素通り
する（Checkov は `--soft-fail` 運用のためブロックしない）。**これこそ第3層が保険を
掛けようとしていたシナリオ**だが、境界を1本増やすより rego の許可リストで塞ぐ方が
安く、診断性も高い。**#666 として切り出した。**

**再検討トリガー:**

- `ci_deploy` に AWS マネージドポリシーを常用する必要が生じたとき
  （#666 の許可リストが形骸化し、静的ゲートの実効性が落ちる）
- 生成先で `ci_deploy` を人間が共用するようになったとき
  （現状は OIDC 専用で、assume できるのは当該リポジトリの GitHub Actions のみ）
- SCP が使えない環境でリージョン上限の二重化が要求されたとき

**採用する場合の設計制約**（この判断を覆すときのために残す）: **`ci_deploy` 自身に張る
境界は、第1層で app ロールに強制する境界とは別の ARN にする。** 同一にすると、
`ci_deploy` 自身が `iam:PermissionsBoundary` 条件を満たすロールになってしまい、課題C の
最短経路（自分自身への `AttachRolePolicy`）が再び通る。

なお、第3層の完了条件として挙げていた「許可の境界がマネージドポリシー10個枠を消費するか」
は **#652 で測定して解消した — 消費しない**（境界を付けた使い捨てロールにマネージド
ポリシーを10本アタッチでき、11本目が `LimitExceeded: PoliciesPerRole: 10` で落ちた）。
枠の懸念は、この判断の理由からは外れている。

### 却下案

- **案1（PowerUserAccess + α）** — 課題A・B は解消するが、スコープ軸が3本とも消え、
  課題C を悪化させる。さらに PowerUserAccess の第2文は
  `iam:CreateServiceLinkedRole` を `Resource: "*"` 無条件で付与しており、
  #651 で予定している同権限の絞り込みを打ち消す。加えて本リポジトリは公開ミラーを持ち
  ハンズオン（#299）の教材でもあり scaffold でコピーされる成果物なので、
  配布物として悪い手本になる。
- **案2（PowerUserAccess + Deny ガードレール）** — 方向性は正しいが、実際に書ける Deny は
  「リージョン + assume 封じ」程度に縮む。`"*:Delete*"` のようなベンダ接頭辞の
  ワイルドカードは `MalformedPolicyDocument` で拒否されるためクロスサービスの Deny は
  サービス全列挙が必要になり（#571 で実機確認済み）、Allow の列挙を Deny の列挙に
  付け替えただけになる。さらに S3 / CloudFront は `aws:RequestedRegion` を当てにできず
  カーブアウトが必須（#45 で確認済み）。**同じ守りを許可の境界がより良い機構で
  実現できる**ため、案2 は案4(a) の下位互換として却下する。
- **現状維持** — 課題A が永続し、課題C が開いたまま残るため却下。

### 本 ADR で扱わないもの

- **`conftest test` の `infra/bootstrap` 適用。** 現在 `conftest test` は
  working-directory が `infra/` のため `infra/bootstrap/` は検査対象外であり、
  `ci_deploy` のポリシーが `iam_wildcard.rego` / `region_condition.rego` に違反しても
  CI は緑のまま通る。これはどの案を選んでも独立して存在する穴だが、`infra/bootstrap` が
  `cd-infra.yml` の管理外であるため plan JSON の用意方法から設計が要る。
  **別 issue に切り、第2層の rego 緩和より先に実施する。** 緩和の便益は bootstrap 側に
  しか無い一方、緩和自体は `infra/` app 層と下流の生成先（ADR-0019）の検査を即座に
  緩めるため、順序を逆にすると「便益ゼロで検査だけ緩い」期間が生じる。実施順は
  **#651 → 第1層 → conftest の bootstrap 適用 → 第2層 → #652** とする
  （提案書 7. の
  項目9 を本 ADR で更新）。
- **SCP（組織レベルの境界）。** 本ワークスペースの AWS アカウントは Organizations 配下
  （`o-vk7n7tsw3t`、FeatureSet `ALL`、SCP 有効）であることが判明したが、SCP は管理アカウント側で
  適用するもので scaffold 配布物には載らない。生成先が Organizations 配下とも、
  管理アカウントへのアクセス権があるとも限らない。扱うなら `docs/org-rulesets.md`（#295）と
  同じ「設計のみ・未適用」の位置づけの別ドキュメントが適切であり、本 ADR の対象外とする。

## Consequences

- **良い面:** 現時点で実在する権限昇格経路（課題C）— `ci_deploy` 自身への
  `AttachRolePolicy` による1ステップの自己昇格を含む — が塞がる。第2層により、
  「スコープ済みリソースへのプロバイダの予測外呼び出し」クラスが構造的に
  消え、#631 / #640 のような sandbox 往復が減る。リソース ARN 軸とリージョン軸は
  維持されるので、#45 の最小権限の姿勢と配布テンプレートとしての説明可能性は保たれる。
  副次的に identity policy の総量が縮み、#652 のポリシー統合も容易になる。
- **悪い面・負担:**
  - 第2層を入れても `Resource = "*"` の文（`Ec2Networking` /
    `LambdaEventSourceMappings` / KMS 系など）の後追いは残る。#651 の
    `ec2:ModifySecurityGroupRules`、#437 の `ec2:GetSecurityGroupsForVpc`、#587 の
    S3 デフォルト KMS キー、#640 の ESM `ListTags` のクラスは今後も実 apply で
    顕在化しうる。
  - 許可の境界に起因する deny は、単純な「その action が無い」より原因が分かりにくい。
    `ci-deploy-iam-gap` スキルの Mode A（reactive）に境界を疑う手順を足す必要がある。
  - 第1層は `ci_deploy` が作る ECS タスクロール / タスク実行ロールの実効権限を変える。
    **境界がアプリ側ロールを絞りすぎないこと**を実機で確認する必要がある。
  - 第1層は bootstrap 層だけで閉じず app 層（`infra/*.tf`）の変更を伴う。既存環境では
    ロールに境界が付くまで更新・削除系が deny される移行の窓があり、bootstrap と
    app 層の適用順序を誤ると apply が止まる。
  - `iam_wildcard.rego` の緩和は、テンプレート生成先にも配布される（ADR-0019）。
    下流のポリシー判定が緩む方向の変更である点は認識しておく。
- **検証要件（`docs/sandbox.md` / #631 の教訓）:** 机上レビューでは検出できない
  失敗モードがあるため、各層について sandbox 実機で
  apply → 変更 → 再 apply → destroy のフルサイクルを通す。とくに以下は実機確認必須:
  - 第1層適用後、ECS タスクロール / タスク実行ロールが境界付きで作成され、
    かつアプリが正常に動作すること
  - **境界未設定の既存ロールがある状態からの移行。** sandbox は毎回まっさらから
    作り直すため新規作成経路しか通らず、移行時の deny（`AttachRolePolicy` /
    `PutRolePolicy` が対象ロールの境界を評価する件）を踏まない。既存ロールを
    残したまま bootstrap → app 層の順に apply → 再 apply → destroy を通す
    シナリオを別途組む
  - 第2層適用後、`aws s3 sync` / CloudFront 操作が誤 deny されないこと
  - ~~（第3層に進む場合）許可の境界がマネージドポリシー10個枠を消費しないこと。
    これは **AWS ドキュメントに明記が無い**ため推測で進めない~~
    → #652 で測定済み。**消費しない**（境界付きロールに10本アタッチでき、11本目が
    `LimitExceeded: PoliciesPerRole: 10`）
- **再検討トリガー:**
  - ~~第1・2層の完了後、第3層（`ci_deploy` 自身への境界）の費用対効果を再評価する。~~
    → 2026-07-25 に再評価し、**採用しない**と決めた（第3層のセクション参照）。残る
    ドリフト経路（AWS マネージドポリシーのアタッチ）は #666 で塞ぐ。
  - `Ec2Networking` 由来の後追いが第2層適用後も繰り返し発生するようなら、
    EC2 について別のスコープ手段（タグベースの認可など）を検討する。
  - マネージドポリシー枠が再び逼迫した場合は #652 の統合案に戻る。
