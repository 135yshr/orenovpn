# 設定プリセット

`terraform.tfvars` をゼロから書く代わりに、目的に合ったプリセットを選んでコピーすれば、
セキュリティ方針まで含めた設定が一括で入ります。**編集は認証情報とSSH公開鍵だけ**
（②③は自分のIPも）で済みます。

| プリセット | ファイル | VPN方式 | 概要 | SSH接続元 |
|-----------|----------|---------|------|-----------|
| ① 簡単・すぐ使える | `01-simple.tfvars` | WireGuard | 最短で動かす。既定のまま安全機能ON | 全開放 |
| ② 最低限セキュリティ | `02-balanced.tfvars` | WireGuard | 常用向け推奨ベースライン | 自分のIPに制限 |
| ③ 最高のセキュア | `03-hardened.tfvars` | WireGuard | 攻撃面を最小化・管理経路を厳格化・通信監視あり | 固定IPのみ厳格 |
| ④ Apple標準VPN | `04-ikev2-apple.tfvars` | IKEv2 | iPhone/macOS 標準VPNでアプリ不要接続 | 全開放 |

WireGuard 系（①②③）は専用アプリ（無料）で接続、④ IKEv2 は Apple 標準VPNに
`.mobileconfig` をワンタップ導入して接続します。

## プリセットごとの任意機能

| 機能 | ① simple | ② balanced | ③ hardened | ④ ikev2 |
|------|:--------:|:----------:|:----------:|:-------:|
| fail2ban / 自動更新<br>`enable_fail2ban` / `enable_auto_updates` | ON | ON | ON | ON |
| IKEv2 証明書の失効(CRL)<br>`enable_cert_revocation` | ON（既定） | ON（既定） | ON（既定） | ON（既定） |
| 通信監視・メール警告<br>`enable_traffic_alert` / `alert_email` / `smtp_*` / `mail_from` | – | – | **ON**（要 `alert_email` / 送信設定） | – |
| 悪性IPへの通信検知<br>`alert_blocklist_url` | – | – | 例をコメントで用意 | – |
| 接続先の記録（宛先IP）<br>`enable_access_log` / `log_retention_days` | – | – | **ON** | – |
| DNS 記録（ドメイン名）<br>`enable_dns_logging` | – | – | コメントを外せば ON | – |
| SSH 接続元の制限<br>`allowed_ssh_cidr` | 全開放 | 自分のIP | 固定IPのみ（必須） | 全開放 |

- 記録・監視は**プライバシーに関わります**。他人の端末も接続する場合は、閲覧履歴に相当する
  情報が残ることを伝えてから有効化してください（[`ALERTING.md`](../../docs/ALERTING.md)）。
- ③ は `smtp_mode = "local"`（VPN 上の `dma` が直接配送・外部 SMTP 不要）も選べます。
  その場合 `mail_from` を**自分が管理するドメイン**のアドレスにする必要があります。
- 既存サーバーへ後から入れる場合は `make configure-alerts` / `make configure-logging` を使います
  （cloud-init は初回のみ動くため、tfvars の変更は既存 VPS に届きません）。

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
