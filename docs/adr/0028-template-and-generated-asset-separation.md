# ADR-0028: 開発用 → 公開用 → 生成先の資産分離は `publish` / `generate` の2軸で宣言し、両導線の除外をそこから導出する

- **Status:** Accepted
- **Date:** 2026-07-31
- **Deciders:** itouhi
- **Audience:** publish
- **Related:** [Epic #698](https://github.com/iwata-jawsug-jp/devcon/issues/698)（#699〜#704）、
  提案書（PR #697）、
  [ADR-0010](0010-adopt-copier-for-scaffold-cli.md)（copier 採用）、
  [ADR-0011](0011-scaffold-template-in-place.md)（in-place テンプレート化）、
  [ADR-0001](0001-record-architecture-decisions.md)（Accepted な ADR は書き換えない）、#287、#298、#515

> **Audience 表記について:** 本 ADR で導入する分類（[Decision](#decision) の D1）を本 ADR 自身に適用している。
> `publish` のみ＝公開用リポジトリまでは出すが、copier 生成先には出さない。他の ADR への一括付与は #704。

## Context

本リポジトリの資産は、2段の導線を通って絞り込まれる。

```
[開発用] iwata-jawsug-jp/devcon
   │  publish.yml → publish-to-public.sh（EXCLUDES / ブロック除外 / 参照掃除 / 文字列置換）
   ▼
[公開用] iwata-jawsug-jp/devcon ＝ モノレポのゴールデンパスのテンプレート
   │  copier copy（copier.yml の _exclude / _tasks の sed）
   ▼
[生成先] 第三者のプロダクトリポジトリ
```

この2つの導線は同じ「資産を絞り込む」処理を担うが、別々に育ってきた。実際に両方を流して測定した結果
（copier 9.17.0、`main` = `ca3f546`。Markdown 相対リンクの解決可否、プレースホルダ表記の誤検出を除く）:

| ツリー                          | リンク切れ |
| ------------------------------- | ---------: |
| 開発用 `iwata-jawsug-jp/devcon`   |          0 |
| 公開用 `iwata-jawsug-jp/devcon` |          1 |
| 生成先（開発用ツリー起点）      |         57 |
| 生成先（公開用ツリー起点）      |         41 |

さらに、2つの生成先は**含まれるファイル自体が違う**（`.github/dependabot.yml` と issue テンプレート4件）。

判明した構造的な問題は次の4点。

