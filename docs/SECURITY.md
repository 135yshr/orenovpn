# セキュリティ設計と追加対策

参考記事の最小構成に対し、本テンプレートが追加している防御と、さらに堅牢化する
ための任意設定をまとめます。

## テンプレートが自動で施す防御

### ネットワーク層（多層防御）

- **ConoHa セキュリティグループ**（クラウド側 FW）で最小許可
  - SSH（22番固定）… `allowed_ssh_cidr` で送信元を制限可能
  - WireGuard（`wg_port`/UDP）… VPN 接続に必要
  - ICMP … 疎通確認用
  - それ以外の受信はすべて拒否
  - ※ `enable_profile_download = true`（既定）のときは QR 配布のため 80/443 が
    **常時 SG 許可**になる（ConoHa は後付け SG ルールを反映しないため）。実際に
    待ち受けるのは `make serve-profile` 実行中のみ。
- **ufw**（サーバー内 FW）で同じポリシーを二重化（default deny incoming）
- **転送(FORWARD)は既定 DROP**。VPN に必要な向きだけを明示許可する
  - WireGuard: `トンネル→WAN` / `トンネル内同士` / `確立済みの戻り` のみ許可、
    MASQUERADE は VPN サブネット限定
  - IKEv2: `-m policy --pol ipsec` で「IPsec SA を通ってきたパケット」だけを転送
  - これにより、外部から「宛先=VPN サブネット」の平文パケットを送っても
    トンネルへは入らず、サーバーが第三者の中継（踏み台/リフレクタ）にもならない

### SSH 堅牢化

| 設定 | 値 | 効果 |
|------|-----|------|
| `PasswordAuthentication` | no | パスワード総当たりを封じる |
| `KbdInteractiveAuthentication` | no | 対話認証も無効化 |
| `PubkeyAuthentication` | yes | 鍵認証のみ許可 |
| `PermitRootLogin` | prohibit-password | root は**鍵ならログイン可**（設定不備時のフォールバック） |
| `Port` | 22（固定）| ポート変更は非対応（Debianの SSH socket で反映されず接続不能になり得るため）|
| `AllowUsers` | 設定しない | `admin_user` と root の両方を残しロックアウトを避ける方針 |
| `MaxAuthTries` | 5 | 試行回数を制限（鍵を複数持つ端末でも弾かれない値） |
| `X11Forwarding` | no | 不要な機能を無効化 |

管理ユーザーはパスワードロック（`lock_passwd: true`）済み。

> **root 鍵ログインを塞ぐ場合**（管理ユーザーでの sudo 経路が確立できたら推奨）:
>
> ```bash
> make ssh
> sudo sed -i 's/^PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config.d/99-orenovpn.conf
> sudo systemctl reload ssh
> ```
>
> `allowed_ssh_cidr` の既定は `["0.0.0.0/0"]`（どこからでも SSH 到達可）です。
> 固定 IP があるなら必ず絞ってください（下記「追加で行うと良い対策」1.）。

### WireGuard の暗号強度

- 最新の暗号スイート（Curve25519 鍵交換 / ChaCha20-Poly1305 暗号化）
- **事前共有鍵（PresharedKey）** を全クライアントに付与し、対称鍵による
  追加の防御層を重ねる（将来の量子計算に対する保険）
- サーバー秘密鍵・クライアント設定は `600` パーミッションで保護

### 資格情報のライフサイクル（漏洩したときに止められるか）

VPN の実質的な認証はクライアント資格情報の管理です。**「配ったものを後から無効化
できるか」**が守りの本体になります。

| プロトコル | 資格情報 | 無効化の方法 |
|---|---|---|
| WireGuard | クライアント秘密鍵 + PSK（`.conf`） | `make remove NAME=x` でサーバーからピアを削除すれば**即座に接続不可** |
| IKEv2 | クライアント証明書 + 鍵（`.mobileconfig` 内の p12） | `enable_cert_revocation = true`（**既定**）なら `make remove NAME=x` で CRL 失効。false だと**止める手段が無い**（証明書は 10 年有効） |

- IKEv2 で `enable_cert_revocation = false` にすると、`make remove` はファイル削除
  だけになり、コピーされた `.mobileconfig` は失効できません。既定の true を維持して
  ください（`make doctor` が false を FAIL として検出します）。
- 失効を有効化する**前に**発行された証明書は CA データベース未登録のため失効できません。
  その場合は CA と全クライアントの作り直し（`sudo rm -rf /etc/orenovpn/pki` →
  `make setup` → 全端末の `make client`）が必要です。
- CRL は「新しい認証」時に効きます。確立中のセッションを切るには
  `sudo swanctl --terminate --ike orenovpn` を併用してください。

### 構成プロファイル/設定の配布

配布物（`.mobileconfig` / `.conf`）は**それ自体が VPN の資格情報**です。IKEv2 の
`.mobileconfig` は p12 とその復号パスワードを同一ファイルに平文で含みます。

- `make serve-profile` の一時 HTTPS 配信は、トークン完全一致・Host 一致・
  ダウンロード回数上限（既定2回）・時間上限（既定180秒）・サーバー側 watchdog による
  強制クローズ・全要求のログ記録で守っています（詳細は
  [`USAGE.md`](USAGE.md#1-a-qr-で-iphone-に直接取得make-serve-profile)）。
- 配信ポートは `enable_profile_download = true`（既定）だと SG では常時開いています。
  待受があるのは配信中だけですが、**配信中は世界中から到達可能**である前提で扱います。
- `make profile` で手元に落としたファイルは 0600 で保存されます。転送は AirDrop 等の
  直接手段を使い、メール/クラウド/チャットには載せないでください（履歴に残った資格情報は
  回収できません）。端末へ入れたら手元のファイルは削除します。

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

### 7. 通信監視・警告（任意）

`enable_traffic_alert = true` にすると、`watch.sh` を systemd timer で **5 分ごと**に実行し、
次の兆候を検知して `msmtp` でメール通知します。

- SSH 認証失敗の急増（`alert_ssh_fail_threshold`、既定 20 回/周期）
- VPN への新規クライアント接続
- 転送量の急増（`alert_traffic_mbytes`、既定 1024 MB/周期）
- （`alert_blocklist_url` 設定時）悪性 IP への出口通信

有効化には `enable_traffic_alert = true` に加え、通知先の `alert_email` と
SMTP 送信設定（`smtp_host` / `smtp_port` / `smtp_user` / `smtp_password`）が必要です。
自前 SMTP サーバーを使う場合は `smtp_auth = "off"` で認証なし運用も可能です（その際 `smtp_user` / `smtp_password` は不要）。

外部 SMTP を用意できない場合は、VPN 上のローカル MTA（`dma`）モードも選べます（`make configure-alerts` の方式③）。
ローカル MTA モードは**待受ソケットを持たず中継しない**（ローカル投函のみで宛先へ直接配送）ため、オープンリレーの心配がありません。
直接配送はメールの到達性のため、DNS 逆引き（PTR）と SPF（可能なら DKIM）の設定を推奨します。

> ⚠️ **重要**: `smtp_password` は **Terraform state と `/etc/orenovpn/orenovpn.env`（0600）に
> 平文で保存**されます。送信専用アカウントやアプリパスワードの利用を推奨します。
> state に残したくない場合は、`make setup` 後にサーバー上の `/etc/msmtprc` を手動設定する
> 運用も可能です。

詳細は [`ALERTING.md`](ALERTING.md) を参照してください。

## インシデント時の初動

「知らない接続がある」「通信量がおかしい」と感じたときの順序。

```bash
# 1. 構成の穴を機械的に点検（転送の全許可・配信ポートの開放漏れ・CRL 無効などを検出）
make doctor

# 2. 現在の接続元を確認（正規端末の回線と一致するか）
make ssh
sudo wg show                        # WireGuard: peer ごとの endpoint と最終handshake
sudo swanctl --list-sas             # IKEv2: remote 'ID' @ IP
sudo tail -n 100 /var/log/orenovpn-serve.log   # 配信ポートへ来た要求の記録
sudo journalctl -u ssh --since "24 hours ago" | grep -Ei 'Accepted|Failed'
sudo fail2ban-client status sshd
last -F

# 3. 疑わしいクライアントを止める
make remove NAME=<疑わしいクライアント>     # WireGuard は即遮断 / IKEv2 は CRL 失効
sudo swanctl --terminate --ike orenovpn      # IKEv2: 確立中セッションも切る
```

**同じ鍵/証明書を複製された疑いがある場合**（`wg show` で 1 つの peer の endpoint が
自分の回線でない IP に変わっている、監視から「資格情報の複製」警告が来た等）は、
その鍵を作り直すしか止める方法がありません:

```bash
make remove NAME=phone && make client NAME=phone   # 鍵/証明書を新しくする
```

**サーバー自体の侵害が疑われる場合**（不審な SSH ログイン成功、CA 鍵の流出可能性）は、
CA・サーバー鍵・全クライアントを作り直します。IKEv2 の CA 秘密鍵はこの VPS 上にあり、
CA は各端末に**信頼されたルート証明書**として入っているため、流出時の影響は VPN に
留まりません（端末の TLS 全体を偽装され得る）。この場合は VPS を作り直し、各端末から
古いプロファイル（CA を含む）を削除してください。
