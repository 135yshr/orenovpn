# 設定プリセット

`terraform.tfvars` をゼロから書く代わりに、目的に合ったプリセットを選んでコピーすれば、
セキュリティ方針まで含めた設定が一括で入ります。**編集は認証情報とSSH公開鍵だけ**
（②③は自分のIPも）で済みます。

| プリセット | ファイル | 概要 | SSH接続元 | ポート | DNS |
|-----------|----------|------|-----------|--------|-----|
| ① 簡単・すぐ使える | `01-simple.tfvars` | 最短で動かす。既定のまま安全機能ON | 全開放 | 既定 | Cloudflare |
| ② 最低限セキュリティ | `02-balanced.tfvars` | 常用向け推奨ベースライン | 自分のIPに制限 | 独自(40022) | Cloudflare |
| ③ 最高のセキュア | `03-hardened.tfvars` | 攻撃面を最小化・管理経路を厳格化 | 固定IPのみ厳格 | 独自(58022) | Quad9 |

## 使い方

```bash
# プロジェクトルートで、いずれかを適用
make preset PRESET=simple      # ①
make preset PRESET=balanced    # ②
make preset PRESET=hardened    # ③

# → terraform/terraform.tfvars が作成される。開いて認証情報・SSH公開鍵を編集
#   （②③は allowed_ssh_cidr を自分のIPに変更）
```

`make` を使わない場合:

```bash
cp terraform/presets/02-balanced.tfvars terraform/terraform.tfvars
```

> ⚠️ 認証情報は**コピー後の `terraform/terraform.tfvars`**（.gitignore 済み）に書いてください。
> このディレクトリのプリセット原本にはプレースホルダのまま実際の秘密情報を書かないこと。

全変数の一覧と説明は [`../terraform.tfvars.example`](../terraform.tfvars.example) を参照。
各対策の詳細は [`../../docs/SECURITY.md`](../../docs/SECURITY.md) を参照してください。
