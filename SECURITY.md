# セキュリティポリシー

## 対象範囲

このリポジトリは学習・実践用のデモプロジェクトで、公開用リポジトリ
（[`iwata-jawsug-jp/devcon`](https://github.com/iwata-jawsug-jp/devcon)）を fork して各自の
AWS 環境にデプロイする構成です。このポリシーが対象とするのは **本リポジトリが提供するコード・
Terraform テンプレート・CI/CD ワークフロー自体の脆弱性**（例: 依存パッケージの既知脆弱性、
インフラ定義の設定ミスによる意図しない公開範囲、CI/CD のシークレット漏洩経路など）です。

fork 後に各自の AWS アカウントへ加えた変更・運用ミスはこの対象外です。

## サポート対象バージョン

個人の学習用プロジェクトのため LTS 運用は行わず、**最新リリース（`main` の最新版）のみ**を
サポートします。過去バージョンへの遡及対応は行いません。

## 脆弱性の報告方法

**公開 Issue は使わないでください。** 脆弱性は GitHub の
[Private Vulnerability Reporting](https://github.com/iwata-jawsug-jp/devcon/security/advisories/new)
から報告してください（`iwata-jawsug-jp/devcon` の **Security** タブ →
**Report a vulnerability**）。

報告には次を含めてください。

- 対象ファイル・箇所（可能であれば commit / タグ）
- 再現手順、または PoC
- 想定される影響

個人運用のプロジェクトのため対応 SLA は設けていませんが、報告を確認次第、可能な範囲で速やかに
triage し、必要な修正は非公開でやり取りしたうえで CVE 番号取得・公開の要否を判断します。
