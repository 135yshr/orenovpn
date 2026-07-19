# 設定プリセット

`terraform.tfvars` をゼロから書く代わりに、目的に合ったプリセットを選んでコピーすれば、
セキュリティ方針まで含めた設定が一括で入ります。**編集は認証情報とSSH公開鍵だけ**
（②③は自分のIPも）で済みます。

| プリセット | ファイル | VPN方式 | 概要 | SSH接続元 |
|-----------|----------|---------|------|-----------|
| ① 簡単・すぐ使える | `01-simple.tfvars` | WireGuard | 最短で動かす。既定のまま安全機能ON | 全開放 |
| ② 最低限セキュリティ | `02-balanced.tfvars` | WireGuard | 常用向け推奨ベースライン | 自分のIPに制限 |
| ③ 最高のセキュア | `03-hardened.tfvars` | WireGuard | 攻撃面を最小化・管理経路を厳格化 | 固定IPのみ厳格 |
| ④ Apple標準VPN | `04-ikev2-apple.tfvars` | IKEv2 | iPhone/macOS 標準VPNでアプリ不要接続 | 全開放 |

WireGuard 系（①②③）は専用アプリ（無料）で接続、④ IKEv2 は Apple 標準VPNに
`.mobileconfig` をワンタップ導入して接続します。

## 使い方

```bash
# プロジェクトルートで、いずれかを適用
make preset PRESET=simple      # ①
make preset PRESET=balanced    # ②
make preset PRESET=hardened    # ③
make preset PRESET=ikev2       # ④（Apple標準VPN）

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
