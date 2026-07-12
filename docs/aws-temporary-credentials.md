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

## 関連ドキュメント

- [README.md「AWS SSO 初期設定」](../README.md#aws-sso-初期設定) — 既定の推奨手順（IAM Identity
  Center）
- [infra/bootstrap/README.md](../infra/bootstrap/README.md) — これらのクレデンシャルで実行する
  `infra/bootstrap` の apply 手順
- [CLAUDE.md](../CLAUDE.md) — 「No long-lived AWS keys」の方針（CI 側は GitHub OIDC で長期キー
  を持たない。本ドキュメントの手法はあくまでローカル/人手作業向けの代替）
