# AWS 一時クレデンシャル発行手順（IAM Identity Center を使わない場合）

このリポジトリの既定の推奨手順は `tools/script/aws-sso-setup.sh` による **AWS IAM Identity
Center（旧 AWS SSO）** 経由のログイン（[README.md「AWS SSO 初期設定」](../README.md#aws-sso-初期設定)）。
ただし IAM Identity Center は AWS Organizations の管理アカウント側で有効化されている必要があり、
個人アカウントや Organizations 未導入のアカウントでは使えないことがある。

本ドキュメントは、そうしたアカウントで `infra/bootstrap` の apply やローカルでの一時的な AWS
CLI 操作を行うための代替手順をまとめる。いずれも「日常的に使う作業用クレデンシャルは短命にする」
という [CLAUDE.md](../CLAUDE.md) の方針（本番デプロイは GitHub OIDC・長期キーを持たない）に
沿ったものだが、Identity Center ほど徹底はできない手法もある — 各手順の note を参照。

## 比較

| 手順                                | 長期シークレット             | 有効期間の目安             | セットアップの重さ | 向いているケース                                                  |
| ----------------------------------- | ---------------------------- | -------------------------- | ------------------ | ----------------------------------------------------------------- |
| 1. IAM ユーザー + get-session-token | あり（発行専用に限定可能）   | 最大 36h（既定 12h）       | 低                 | 個人/小規模アカウントでの最短ルート（**推奨**）                   |
| 2. IAM ユーザー + assume-role       | あり（権限は最小化）         | 既定 1h（最大 12h）        | 中                 | 権限分離したい・CI の OIDC パターンに近づけたい場合               |
| 3. IAM Roles Anywhere               | なし（証明書ベース）         | 既定 15min〜1h（最大 12h） | 高（PKI 構築）     | 長期シークレットを一切残したくない・失効も即時にしたい場合        |
| 4. AWS CloudShell 経由でのコピー    | なし（コンソールセッション） | 約 1h〜（コンソール依存）  | 最低（都度手動）   | ごく単発の管理操作（本セッションで実施した KMS ウォームアップ等） |

いずれの方法も、それを設定するための**最初の一歩**（IAM ユーザー作成や CloudShell を開くための
コンソールログイン）自体は root ユーザーか既存の IAM ユーザーでの認証が前提になる。Identity
Center を使わない代わりにこれらの初期セットアップが必要になる点は共通の制約。

---

## 1. IAM ユーザー + `get-session-token`（推奨）

MFA 付きの IAM ユーザーで一時セッションを発行する、最も枯れた方法。長期アクセスキーは存在するが
**セッション発行専用**に限定し、`terraform apply` 等の実操作には使わない運用にする。

### セットアップ（初回のみ）

1. IAM コンソールでユーザーを作成（コンソールアクセス不要、プログラムアクセスのみ）。
2. 仮想 MFA デバイスを有効化（`arn:aws:iam::<account-id>:mfa/<user>` が払い出される）。
3. アクセスキーを発行し、`get-session-token` 専用のベースプロファイルとして保存:

   ```bash
   aws configure --profile base
   # AWS Access Key ID / Secret Access Key を入力（Default region: ap-northeast-1）
   ```

### 一時セッションの発行（トークン期限切れのたびに再実行）

```bash
aws sts get-session-token \
  --serial-number arn:aws:iam::<account-id>:mfa/<user> \
  --token-code <MFA コード> \
  --duration-seconds 43200 \
  --profile base
```

出力された `AccessKeyId` / `SecretAccessKey` / `SessionToken` を作業用プロファイルへ書き込む:

```bash
aws configure set aws_access_key_id     <AccessKeyId>     --profile default
aws configure set aws_secret_access_key <SecretAccessKey> --profile default
aws configure set aws_session_token     <SessionToken>    --profile default
aws configure set region                ap-northeast-1    --profile default

aws sts get-caller-identity   # 確認
```

> **Note**: `base` プロファイルの長期キーは `get-session-token` の呼び出し以外に使わない。
> 誤って `terraform apply` 等で長期キーを直接使ってしまわないよう、`base` は
> `~/.aws/credentials` にのみ置き、シェルの `AWS_PROFILE` は普段 `default`（セッション
> トークン側）にしておく。

## 2. IAM ユーザー + `assume-role`

ベースの IAM ユーザーには `sts:AssumeRole` だけを許可し、実際の作業権限は別ロールに寄せる。
CI の GitHub OIDC パターン（低権限の入り口 + ロール分離）に近い考え方をローカルでも再現できる。

### セットアップ（初回のみ）

1. 作業用ロール（例 `local-bootstrap-admin`）を作成し、信頼ポリシーでベース IAM ユーザーの
   ARN を Principal に、`aws:MultiFactorAuthPresent` 条件で MFA 必須にする。
2. ベース IAM ユーザーには、そのロール ARN に対する `sts:AssumeRole` のみを許可する最小権限
   ポリシーを付与し、MFA を有効化してアクセスキーを発行する。
3. `~/.aws/config` にロール引き受け用プロファイルを定義する:

   ```ini
   [profile base]
   region = ap-northeast-1

   [profile admin]
   role_arn        = arn:aws:iam::<account-id>:role/local-bootstrap-admin
   source_profile  = base
   mfa_serial      = arn:aws:iam::<account-id>:mfa/<user>
   duration_seconds = 3600
   region = ap-northeast-1
   ```

   ベースの長期キーは `aws configure --profile base` で登録しておく。

### 利用

```bash
aws sts get-caller-identity --profile admin
# MFA コードの入力を求められる。AWS CLI が内部で AssumeRole を呼び、
# 一時クレデンシャルを ~/.aws/cli/cache にキャッシュ・自動更新する
```

`AWS_PROFILE=admin` を設定しておけば、以降のコマンド（`terraform apply` など）は自動的に
一時クレデンシャルを使う。

## 3. IAM Roles Anywhere

X.509 クライアント証明書による信頼関係で一時クレデンシャルを発行する。IAM ユーザーの長期
アクセスキー自体が存在しないため、4 手法の中で最も長期シークレットを残さない構成。その分
PKI（認証局・証明書）の構築が必要で、セットアップは最も重い。

### セットアップ（初回のみ）

1. 認証局（CA）を用意する。個人/小規模アカウントなら自己署名 CA で十分:

   ```bash
   openssl req -x509 -newkey rsa:4096 -days 3650 -nodes \
     -keyout ca-key.pem -out ca-cert.pem -subj "/CN=local-dev-ca"
   ```

2. その CA を IAM Roles Anywhere の **Trust Anchor** として登録する:

   ```bash
   aws rolesanywhere create-trust-anchor \
     --name local-dev \
     --source "sourceType=CERTIFICATE_BUNDLE,sourceData={x509CertificateData=$(cat ca-cert.pem)}" \
     --enabled
   ```

3. `rolesanywhere.amazonaws.com` を信頼する IAM ロールを作成する（信頼ポリシーで
   `aws:PrincipalTag` 等により Trust Anchor を紐付ける）。
4. そのロールに紐づく **Profile** を作成する:

   ```bash
   aws rolesanywhere create-profile \
     --name local-dev --role-arns arn:aws:iam::<account-id>:role/local-dev-rolesanywhere \
     --enabled
   ```

5. 自分のマシン用のエンドエンティティ証明書を CA で発行し、秘密鍵はローカルに保管する:

   ```bash
   openssl req -newkey rsa:2048 -nodes -keyout client-key.pem -out client-req.pem \
     -subj "/CN=$(whoami)"
   openssl x509 -req -in client-req.pem -CA ca-cert.pem -CAkey ca-key.pem \
     -CAcreateserial -days 365 -out client-cert.pem
   ```

6. [`aws_signing_helper`](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/credential-helper.html)
   を導入し、`credential_process` でプロファイルを定義する:

   ```ini
   [profile roles-anywhere]
   credential_process = aws_signing_helper credential-process \
     --certificate client-cert.pem --private-key client-key.pem \
     --trust-anchor-arn <trust-anchor-arn> \
     --profile-arn <profile-arn> \
     --role-arn arn:aws:iam::<account-id>:role/local-dev-rolesanywhere
   ```

### 利用

```bash
aws sts get-caller-identity --profile roles-anywhere
# 呼び出しのたびに aws_signing_helper が証明書で署名し、短命なクレデンシャルを発行する
```

> 証明書を失効させれば即座にアクセスを止められる（IAM ユーザーの無効化より機動的）。継続的に
> 使う体制なら、この方法か本来の Identity Center への移行を検討する。

## 4. AWS CloudShell 経由でのコピー

ブラウザで AWS コンソールにログインすると、CloudShell はコンソールセッションに紐づく一時
クレデンシャルを自動的に環境変数へ用意している。ローカル側の事前セットアップは不要。

### 手順

1. AWS コンソール（root またはコンソールアクセス権を持つ IAM ユーザー、MFA 推奨）にログインし
   CloudShell を開く。
2. CloudShell 上でクレデンシャルを確認する:

   ```bash
   env | grep ^AWS_
   ```

3. 表示された `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` を、
   ローカル（devcontainer）側で同名の環境変数としてそのセッション限りで export するか、
   `aws configure set ... --profile default` で `~/.aws/credentials` に書き込む。
4. `aws sts get-caller-identity` で確認する。

> **Note**: CloudShell のクレデンシャルはコンソールセッションに紐づき、期限が切れるたびに
> 手動でコピーし直す必要があり、4 手法の中で最も手間がかかる。セットアップなしで即座に使える
> 反面、コピー&ペーストの過程でシェル履歴やクリップボード履歴に残りやすいので、使い終えたら
> `history -c` 等で消し、ファイルには保存しないこと。ルーティンの開発作業には向かず、今回の
> KMS デフォルトキーのウォームアップのような単発の管理操作に向いている。

---

## 5. `agent-mcp` ロール（AWS MCP Server 用、#571）を引き受ける

`infra/bootstrap/` が作る `<project>-<suffix>-agent-mcp`（`<suffix>`は`terraform output -raw
resource_name_suffix`で確認できるランダム6文字）ロールは、Claude Code が AWS MCP Server
経由でこのAWSアカウントを読み取る際に使う、CIとは無関係の**エージェント専用ロール**（設計は
[infrastructure.md「Terraform 2 層構成」](infrastructure.md#1-infrabootstrap初回のみローカル-state)
参照）。信頼ポリシーは account root principal のため、**個別に `sts:AssumeRole` を許可された
IAM ユーザー/ロールであれば誰でも引き受けられる**。

### AWS SSO（IAM Identity Center）でログイン済みの場合

`tools/script/aws-sso-setup.sh agent-mcp` が以下を自動化する:

```bash
tools/script/aws-sso-setup.sh agent-mcp                 # デフォルトのSSOプロファイル("default")を使う
tools/script/aws-sso-setup.sh agent-mcp --sso-profile dev  # 別名プロファイルの場合
```

SSOプロファイルの認証状態を確認（未ログインなら`aws sso login`を自動実行）し、
`infra/bootstrap`のローカルstateから`agent_mcp_role_arn`を自動検出して（無ければ
`--role-arn`で明示指定）、`~/.aws/config`に`agent-mcp`プロファイル（`role_arn` +
`source_profile`）を書き込み、`sts get-caller-identity`で疎通確認する。

SSOのpermission setが`AWSAdministratorAccess`相当（`aws-sso-setup.sh login`の既定値）なら
追加の権限付与は不要なことが多い。`AccessDenied`になる場合は、そのpermission setに
下記のインラインポリシーと同等の許可を追加する必要がある（IAM Identity Center側の設定は
このリポジトリのTerraform管理対象外）。

### IAM ユーザー + assume-role（上記セクション2）を使っている場合の手動セットアップ

SSOではなく上記セクション2のベースIAMユーザーパターンを使っている場合は、以下を手動で行う
（`aws-sso-setup.sh agent-mcp`と同じ結果を、SSOを使わずに得る手順）。

#### セットアップ（初回のみ）

1. 上記セクション2のセットアップ済みベース IAM ユーザーに、`agent-mcp` ロールへの
   `sts:AssumeRole` を追加で許可する（既存の `local-bootstrap-admin` 用ポリシーに
   リソースを追記するか、`agent-mcp` 専用の別ポリシーを付与する）:

   ```json
   {
     "Effect": "Allow",
     "Action": "sts:AssumeRole",
     "Resource": "arn:aws:iam::<account-id>:role/<project>-<suffix>-agent-mcp"
   }
   ```

   このロール自身は Terraform 管理だが、ベース IAM ユーザー側への許可付与はこのリポジトリの
   Terraform 管理対象外（ベース IAM ユーザー自体がこのリポジトリの外で作られるため）。

2. `~/.aws/config` に専用プロファイルを追加する（`role_arn` を `agent-mcp` のARNに差し替える
   だけで、他はセクション2の `admin` プロファイルと同じ）:

   ```ini
   [profile agent-mcp]
   role_arn        = arn:aws:iam::<account-id>:role/<project>-<suffix>-agent-mcp
   source_profile  = base
   mfa_serial      = arn:aws:iam::<account-id>:mfa/<user>
   duration_seconds = 3600
   region = ap-northeast-1
   ```

#### 利用

```bash
aws sts get-caller-identity --profile agent-mcp
```

（`aws-sso-setup.sh agent-mcp`を使った場合も、同名の`agent-mcp`プロファイルが同じ形で
書き込まれるので、以降はこのコマンドで疎通確認できる。）

このプロファイル自体は「ロールを引き受けられること」の確認用。**実際に AWS MCP Server が
使う認証情報は、`.mcp.json` の `aws` エントリ（[#572](https://github.com/iwata-jawsug-jp/devcon/issues/572)
で実装済み、`docs/development-environment.md` 参照）が `mcp-proxy-for-aws --profile agent-mcp`
としてこのプロファイルを直接指定することで、`agent-mcp` ロールを経由する。** OAuth方式
（ブラウザでのAWS Sign-in）ではなく SigV4 方式でなければこのロールは経由しない、という
選定理由も #572 で記録済み。

> **Note**: `DenyUnlessViaAWSMCP` により、このロールの一時クレデンシャルは AWS MCP Server の
> プロキシを経由しないリクエスト（例えば `aws sts get-caller-identity --profile agent-mcp`
> を含む、素の AWS CLI/SDK からの呼び出し全般）では `aws:ViaAWSMCPService` コンテキストキーが
> 立たないため、**読み取り系を含め全アクションが Deny される**。上記の `get-caller-identity`
> 疎通確認だけは STS が対象外なので通るが、それ以外のAWS API呼び出しをこのプロファイルで
> 直接試しても意図的に失敗する。実際に権限があることの確認は AWS MCP Server 経由でのみ行える。

### CloudTrail での監査（提案書4.3節、runbook）

ダウンストリームAWS API呼び出しは `userIdentity.invokedBy` に呼び出し元MCPサーバーのサービス
プリンシパル（`aws-mcp.amazonaws.com`）が記録される
（[AWS公式ドキュメント](https://docs.aws.amazon.com/agent-toolkit/latest/userguide/logging-using-cloudtrail.html)）。
CloudTrail Lake でMCP経由の操作だけを抽出するクエリの例:

```sql
SELECT eventTime, eventName, userIdentity.arn, sourceIPAddress
FROM <event-data-store>
WHERE userIdentity.invokedBy = 'aws-mcp.amazonaws.com'
  AND userIdentity.sessionContext.sessionIssuer.arn LIKE '%<project>-<suffix>-agent-mcp'
ORDER BY eventTime DESC
```

異常検知（例: 本来read-onlyのはずのロールで `Deny` された書き込み試行が多発する）は
CloudWatch Logs Insights クエリまたは EventBridge ルールで実装できるが、具体的な閾値・
通知先の設計は本issueのスコープ外。

> **注意: このクエリは本リポジトリの `infra/` にCloudTrail trailが存在しないため未検証。**
> `grep -rn "cloudtrail" infra/` は0件（2026-07時点）。trailの新規作成・データイベント
> 有効化（AWS MCP Server自身の `CallTool` イベントは `eventCategory: "Data"` に分類されるため、
> それも見たい場合は追加でデータイベントロギングが必要）は別issueで検討する。上のクエリは
> 「trailとevent data storeが用意された前提でのSQL構文」の記録であり、実データでの動作確認は
> 済んでいない。

---

## 関連ドキュメント

- [README.md「AWS SSO 初期設定」](../README.md#aws-sso-初期設定) — 既定の推奨手順（IAM Identity
  Center）
- [infra/bootstrap/README.md](../infra/bootstrap/README.md) — これらのクレデンシャルで実行する
  `infra/bootstrap` の apply 手順
- [CLAUDE.md](../CLAUDE.md) — 「No long-lived AWS keys」の方針（CI 側は GitHub OIDC で長期キー
  を持たない。本ドキュメントの手法はあくまでローカル/人手作業向けの代替）
