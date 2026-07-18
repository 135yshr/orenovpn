# セキュリティ設計と追加対策

参考記事の最小構成に対し、本テンプレートが追加している防御と、さらに堅牢化する
ための任意設定をまとめます。

## テンプレートが自動で施す防御

### ネットワーク層（多層防御）

- **ConoHa セキュリティグループ**（クラウド側 FW）で最小許可
  - SSH（`ssh_port`）… `allowed_ssh_cidr` で送信元を制限可能
  - WireGuard（`wg_port`/UDP）… VPN 接続に必要
  - ICMP … 疎通確認用
  - それ以外の受信はすべて拒否
- **ufw**（サーバー内 FW）で同じポリシーを二重化（default deny incoming）

### SSH 堅牢化

| 設定 | 値 | 効果 |
|------|-----|------|
| `PasswordAuthentication` | no | パスワード総当たりを封じる |
| `PermitRootLogin` | no | root 直接ログインを禁止 |
| `PubkeyAuthentication` | yes | 鍵認証のみ許可 |
| `Port` | 22（固定）| ポート変更は非対応（Debianの SSH socket で反映されず接続不能になり得るため）|
| `AllowUsers` | 管理ユーザーのみ | ログイン可能なユーザーを限定 |
| `MaxAuthTries` | 3 | 試行回数を制限 |

管理ユーザーはパスワードロック（`lock_passwd: true`）済み。

### WireGuard の暗号強度

- 最新の暗号スイート（Curve25519 鍵交換 / ChaCha20-Poly1305 暗号化）
- **事前共有鍵（PresharedKey）** を全クライアントに付与し、対称鍵による
  追加の防御層を重ねる（将来の量子計算に対する保険）
- サーバー秘密鍵・クライアント設定は `600` パーミッションで保護

### 侵入・改ざん対策

- **fail2ban** … SSH ブルートフォースを検知して自動 BAN
- **unattended-upgrades** … セキュリティ更新を自動適用
- **sysctl 堅牢化** … リダイレクト無効化・rp_filter・SYN cookies・
  martian パケットログ・`kptr_restrict` など

## 追加で行うと良い対策（任意）

### 1. SSH 送信元 IP を固定する（最も効果的）

自宅/オフィスの固定 IP がある場合、`terraform.tfvars` で:

```hcl
allowed_ssh_cidr = ["203.0.113.10/32"]
```

これで SSH は指定 IP からのみ到達可能になります。

### 2. クライアント側 kill switch（VPN 切断時に通信を遮断）

VPN が切れた瞬間に素の回線へフォールバックして IP が漏れるのを防ぎます。

- **公式アプリ**: WireGuard アプリの設定で
  「**Block untunneled traffic (kill-switch)**」を ON にする
  （`AllowedIPs = 0.0.0.0/0, ::/0` のとき自動で選択可能）。
- **Linux（wg-quick）**: クライアント設定に以下を追加すると同等の効果:

  ```ini
  [Interface]
  # ... PrivateKey/Address/DNS ...
  PostUp   = ip route add blackhole default metric 9999
  PreDown  = ip route del blackhole default metric 9999
  ```

### 3. DNS 漏洩対策

- 本テンプレートは `wg_dns`（既定 `1.1.1.1,1.0.0.1`）をクライアントへ配布し、
  トンネル内 DNS を強制します。フルトンネル（`AllowedIPs=0.0.0.0/0,::/0`）の
  場合、DNS クエリも VPN 経由になり漏洩しません。
- プライバシー重視なら `wg_dns = "9.9.9.9"`（Quad9）などへ変更、または
  サーバー上に unbound を立てて自前解決に切り替えることも可能です。

### 4. 監査ログ（auditd）

```bash
make ssh
sudo apt install -y auditd
sudo systemctl enable --now auditd
```

ログイン・権限昇格・設定変更を記録します。

### 5. 鍵の安全な取り扱い

- `terraform.tfvars` / `*.tfstate` は**シークレットを含む**ため
  公開リポジトリへ push しない（`.gitignore` 済み）。
- 認証情報を環境変数で渡す運用も可能:

  ```bash
  export OS_AUTH_URL="https://identity.c3j1.conoha.io/v3"
  export OS_USER_DOMAIN_NAME="gnc"
  export OS_TENANT_NAME="gnct..."
  export OS_USERNAME="gncu..."
  export OS_PASSWORD="..."
  ```

  この場合 `providers.tf` の各項目を削るか、tfvars を空にしておきます。
- Terraform state は機密の塊です。チーム運用ではリモートバックエンド
  （暗号化された S3 互換ストレージ等）+ state ロックの利用を推奨します。

### 6. より強い鍵生成（クライアント側生成）

本テンプレートは利便性のためサーバー上でクライアント秘密鍵を生成します。
最高水準を求める場合は、クライアント端末で鍵を生成し、公開鍵のみをサーバーへ
登録する運用に切り替えてください（秘密鍵がサーバーを経由しなくなります）。

## インシデント時の初動

```bash
# 不審なクライアントを即時遮断
make remove NAME=<疑わしいクライアント>

# サーバーの接続状況を確認
make ssh
sudo wg show               # ハンドシェイク元 IP・転送量
sudo fail2ban-client status sshd
sudo journalctl -u ssh --since "1 hour ago"
```
