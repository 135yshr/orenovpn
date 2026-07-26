# 使い方ガイド

デプロイ後の日常的な使い方（各デバイスからの接続・クライアント管理）をまとめます。
初回セットアップは [`SETUP.md`](SETUP.md)、セキュリティ設定は [`SECURITY.md`](SECURITY.md) を参照してください。

## 目次

- [クライアント管理コマンド](#クライアント管理コマンド)
- [プロトコルによる接続方法の違い](#プロトコルによる接続方法の違い)
- [iPhone / macOS から接続（IKEv2 標準VPN）](#iphone--macos-から接続ikev2-標準vpn)
- [iPhone / iPad から接続（WireGuard）](#iphone--ipad-から接続wireguard)
- [Android から接続](#android-から接続)
- [Mac / Windows / Linux から接続](#mac--windows--linux-から接続)
- [接続状態の確認](#接続状態の確認)（通信監視・アクセス先の記録を含む）
- [よくある操作](#よくある操作)

---

## クライアント管理コマンド

接続したいデバイスごとに「クライアント」を1つ作成します。
プロジェクトルートで `make` を使うのが簡単です。

| コマンド | 内容 |
|----------|------|
| `make client NAME=iphone` | クライアント `iphone` を追加し QR コードを表示 |
| `make show NAME=iphone` | 既存クライアントの設定と QR を再表示 |
| `make clients` | クライアント一覧と接続状態を表示 |
| `make remove NAME=iphone` | クライアント `iphone` を削除 |
| `make doctor` | サーバー構成を自己診断（不通/通信不可の原因切り分け） |

> `NAME` は英数字・ハイフン・アンダースコアのみ。デバイスごとに別名を付けます
> （例: `iphone`, `ipad`, `macbook`, `work-pc`）。**同じ設定を複数端末で使い回さない**でください。

> 💡 SSH 鍵を既定以外のパスに作った場合は、各コマンドに `SSH_KEY=` を付けます。
> 例: `make client NAME=iphone SSH_KEY=~/.ssh/orenovpn`
> （`~/.ssh/config` に書いておけば指定不要。詳細は [SETUP.md](SETUP.md#1-3-ssh-鍵ペアを作成)）

---

## プロトコルによる接続方法の違い

本テンプレートは `vpn_protocol` で 2 方式を選べます。接続手順が異なります。

| | `wireguard`（既定）| `ikev2` |
|--|--------------------|---------|
| アプリ | WireGuard 公式アプリ（無料）| **不要**（iPhone/macOS 標準VPN）|
| 配布物 | QR コード / .conf | **.mobileconfig**（構成プロファイル）|
| 導入 | QR スキャン | プロファイルをインストール |

- WireGuard を使う場合 → [iPhone(WireGuard)](#iphone--ipad-から接続wireguard)
- IKEv2 を使う場合 → [iPhone/Mac(IKEv2)](#iphone--macos-から接続ikev2-標準vpn)

---

## iPhone / macOS から接続（IKEv2 標準VPN）

`vpn_protocol = "ikev2"` の場合。**アプリのインストールは不要**です。

### 1. 構成プロファイルを作成・手元にダウンロード

```bash
make client  NAME=iphone         # クライアント作成（初回のみ）
make profile NAME=iphone         # Mac のカレントディレクトリに iphone.mobileconfig を保存
```

> ⚠️ `.mobileconfig` は**それ自体が VPN の資格情報**です。クライアント証明書(p12)と
> **その復号パスワードが同じファイルに平文で**入っているため、渡した経路（メール・
> クラウド・チャットの履歴）に残った時点で漏洩と同じ扱いになります。取り扱いは
> 秘密鍵と同等にしてください。

> `.mobileconfig` はサーバー上に root 所有で置かれます。取得方法は2通り:
> - **A. QR で iPhone に直接**（`make serve-profile`）… 下記
> - **B. Mac に落として転送**（`make profile` → AirDrop）… その下

### 1-A. QR で iPhone に直接取得（`make serve-profile`）

```bash
make client        NAME=iphone     # クライアント作成（初回のみ）
make serve-profile NAME=iphone     # 一時HTTPS配信 + QR をターミナルに表示
```

1. ターミナルに QR が出る → iPhone の**カメラで撮る** → Safari が開く
2. `.mobileconfig` DL →「設定」→ プロファイルをインストール
   （Let's Encrypt 証明書が取れなかった場合のみ警告 →「詳細を表示」→「このWebサイトにアクセス」）
3. 取得できたら `Ctrl-C`（ダウンロード完了・時間経過でも自動停止し ufw も閉じる）

配信は資格情報を公開ポートに置く操作なので、次の多層で守っています:

| 防御 | 内容 |
|---|---|
| トークン一致のみ応答 | URL のトークンが完全一致しないパスは 404。**ディレクトリ一覧は返さない** |
| Host ヘッダ検査 | 配信ホスト名（`<IP>.sslip.io` または `PROFILE_DOMAIN`）以外は 404。IP 直打ちのスキャンを弾く |
| ダウンロード回数上限 | 既定 2 回で自動停止（`SERVE_MAX_DOWNLOADS` で変更）。到達確認は HEAD なので消費しない |
| 時間上限 | 既定 180 秒（`SERVE_SECONDS`）。サーバー側 watchdog が ufw も必ず閉じる（手元の Ctrl-C や回線状態に依存しない） |
| 複製しない | 配布物は `/etc/orenovpn/clients/`（root のみ）から直接読む。`/tmp` へコピーしない |
| 証跡 | 許可/拒否をすべて `/var/log/orenovpn-serve.log` に記録 |

```bash
# 配信中に誰が叩いてきたかを確認（別ターミナルから）
make ssh
sudo tail -n 50 /var/log/orenovpn-serve.log   # DENY host-mismatch などが並ぶのは通常のスキャン
```

> 配信ポート（既定443）は Terraform で**作成時に SG へ宣言**してあります
> （ConoHa は後付け SG ルールを稼働中インスタンスに反映しないため）。
> 待ち受けるのは `make serve-profile` 実行中のみで、それ以外は接続拒否されます。
>
> なお Let's Encrypt 証明書を取得すると、そのホスト名は **Certificate Transparency
> ログに即時公開**されます（＝配信の開始が第三者から観測可能）。上のトークン一致・
> Host 検査・回数上限は、この前提のうえで必須の防御です。既知ポートを避けたい場合は
> `randomize_profile_port = true`、独自ドメインを使う場合は `PROFILE_DOMAIN` を指定します。

### 1-B. Mac に落として渡す（`make profile`）

QR を使わない/使えない場合。`.mobileconfig` を Mac にダウンロードしてから転送します。

```bash
make profile NAME=iphone           # ./iphone.mobileconfig を 0600 で保存
```

端末への渡し方は次の「2. iPhone へ渡してインストール」を参照してください。
インストールが終わったら手元のファイルは削除します（`rm iphone.mobileconfig`）。

### 2. iPhone へ渡してインストール

Mac に保存された `iphone.mobileconfig` を iPhone へ転送します（いずれか）:

- **AirDrop（推奨）**: Finder で `iphone.mobileconfig` を右クリック →「共有」→「AirDrop」→ iPhone を選択
- メール / iCloud Drive 経由は**非推奨**（資格情報が送信履歴やクラウドに残り、後から回収できない）

iPhone 側:
1. 受け取った `.mobileconfig` を開く →「設定」に「プロファイルがダウンロードされました」
2. 「設定」→「一般」→「VPN とデバイス管理」→ プロファイルを**インストール**

**macOS 自身**で使う場合は、`make profile NAME=mac` で保存した `.mobileconfig` を
ダブルクリック →「システム設定」→「一般」→「デバイス管理」→ **インストール**。

### 3. 接続

「設定」→「VPN」に **orenovpn** が追加されます。トグルを ON で接続完了。
証明書認証のため**パスワード入力は不要**です。

> オンデマンド接続（自動接続）にしたい場合は、VPN 設定で有効化できます。

---

## iPhone / iPad から接続（WireGuard）

`vpn_protocol = "wireguard"`（既定）の場合。

### 1. 公式アプリをインストール

App Store で [**WireGuard**](https://apps.apple.com/app/wireguard/id1441195209)（無料）をインストール。

### 2. QR コードを表示

Mac/PC のターミナルで:

```bash
make client NAME=iphone      # 新規作成（初回）
# すでに作成済みなら:  make show NAME=iphone
```

ターミナルに QR コードが表示されます。

### 3. iPhone で読み取る

1. WireGuard アプリを開く
2. 右上の **「＋」** をタップ
3. **「QR コードから作成」** を選択
4. ターミナルの QR をスキャン
5. トンネル名（例: `orenovpn`）を入力して保存

### 4. 接続

作成したトンネルの**トグルスイッチを ON**。
上部に VPN アイコンが出れば接続完了です。既定はフルトンネル
（`AllowedIPs = 0.0.0.0/0, ::/0`）なので、iPhone の全通信が VPS 経由になります。

### 5. 自動接続（推奨設定）

トンネルを編集 → **「オンデマンド接続」** を有効化すると、
Wi-Fi / モバイル通信への接続時に自動で VPN が張られます。

> QR がターミナルで読み取りにくい場合は、フォントを小さくするか
> ウィンドウを広げてください。QR を使わない方法は
> [下記の「設定ファイルで取り込む」](#設定ファイルで取り込む) を参照。

---

## Android から接続

1. Google Play で [**WireGuard**](https://play.google.com/store/apps/details?id=com.wireguard.android) をインストール
2. `make client NAME=android` で QR を表示
3. アプリ → 「＋」→ **「QR コードをスキャン」** で読み取り
4. トグルを ON

---

## Mac / Windows / Linux から接続

### アプリで取り込む（推奨）

- **Mac**: App Store の [WireGuard](https://apps.apple.com/app/wireguard/id1451685025)
- **Windows**: [公式サイト](https://www.wireguard.com/install/) からインストーラ
- **Linux**: `sudo apt install wireguard`（後述の wg-quick で接続）

### 設定ファイルで取り込む

サーバー上に生成された `.conf` を取得してアプリにインポートします。

```bash
# クライアントを作成（未作成の場合）
make client NAME=macbook

# サーバーから設定ファイルを取得（SSH は 22 番固定）
scp -P 22 vpnadmin@<サーバーIP>:/etc/orenovpn/clients/macbook.conf ./
```

取得した `macbook.conf` を WireGuard アプリの
「ファイルからトンネルを追加」でインポートし、有効化します。

### Linux コマンドライン（wg-quick）

```bash
sudo cp macbook.conf /etc/wireguard/orenovpn.conf
sudo wg-quick up orenovpn        # 接続
sudo wg-quick down orenovpn      # 切断
sudo systemctl enable wg-quick@orenovpn   # 起動時に自動接続
```

---

## 接続状態の確認

```bash
# クライアント一覧とハンドシェイク状況
make clients

# サーバーに入って詳細を見る
make ssh
sudo wg show                 # 各ピアの最終ハンドシェイク・転送量
```

接続できているデバイスは `latest handshake` が数十秒〜2分以内に更新されます。

### 実際に VPN 経由になっているか確認

接続後、デバイスのブラウザで [ifconfig.co](https://ifconfig.co/) などを開き、
表示される IP アドレスが **ConoHa VPS のグローバル IP** になっていれば成功です。

### 通信監視・警告の確認（有効化している場合）

`enable_traffic_alert = true` で構築した場合、次のコマンドで監視の状態を確認できます。

| コマンド | 内容 |
|----------|------|
| `make alerts-status` | 監視（`watch.sh` の systemd timer）が稼働しているか確認 |
| `make alerts-test` | テスト通知メールを送信し SMTP 設定を検証 |
| `make configure-alerts` | 既存サーバーへアラート設定を反映（対話入力で送信方式を 外部SMTP / 自前SMTP / VPN上ローカルMTA の3択から選択。SMTP パスワードを Terraform state に残さない） |

詳細は [`ALERTING.md`](ALERTING.md) を参照してください。

### アクセス先の記録を見る（有効化している場合）

「いつ・どの端末が・どこへ接続したか」の記録です（既定 OFF）。

| コマンド | 内容 |
|----------|------|
| `make access-log` | 宛先 IP/ポートの直近と、宛先ごとの集計（`HOURS=24` で範囲変更）|
| `make dns-log` | DNS 問い合わせ（ドメイン名）の直近と、名前ごとの集計 |
| `make logs-status` | 記録機能の有効/無効・適用ルール・DNS の待受を確認 |
| `make configure-logging ACCESS_LOG=on DNS_LOG=on DAYS=14` | 既存サーバーで有効化（`off` で無効化）|

```bash
make access-log HOURS=24     # 過去24時間の接続先
make dns-log                 # 直近のドメイン名
```

> **完全な URL は記録できません**（TLS で暗号化されているため）。残るのは
> 宛先 IP・ポート・ドメイン名までです。端末が DoH/DoT（暗号化 DNS）を使う場合は
> ドメイン名も記録されません（宛先 IP は残ります）。
>
> 他人の端末も接続している場合、記録は閲覧履歴に相当します。有効化する前に伝えてください。

詳細は [`ALERTING.md`](ALERTING.md#アクセス先の記録宛先ip--ドメイン名) を参照してください。

---

## よくある操作

### 新しいデバイスを追加する

```bash
make client NAME=<好きな名前>
```

### デバイスを紛失した / 接続を無効化したい

```bash
make remove NAME=<該当クライアント>
```

- **WireGuard**: ピアが削除され、即座に接続できなくなります。
- **IKEv2**: 既定ではサーバー上の配布物を消すだけで、**発行済み証明書は失効しません**
  （手元に残っていれば接続に使えてしまう）。厳密に失効させたい場合は
  `enable_cert_revocation = true` で構築し、その状態で発行したクライアントを `make remove`
  すると CRL に登録されて接続できなくなります。それ以前に発行した証明書を確実に無効化するには
  CA を作り直して全クライアントを再発行してください。

### つながらないとき

まず **`make doctor`** で自己診断すると、原因の切り分けが一気に進みます（ファイアウォールの
二重稼働・NAT 未適用・待受ポート・IP 転送・IPv6 プールなどを自動点検）。

```bash
make doctor
```

| 症状 | 確認 |
|------|------|
| そもそも外部から届かない | `make doctor` で nftables の二重稼働や待受ポートを確認。ConoHa 側 SG も確認 |
| 接続はするが通信できない（戻り 0） | `make doctor` の NAT(MASQUERADE) 項目を確認。無ければ `make setup` を再実行 |
| IKEv2 が ON→即 OFF | サーバーログ `journalctl -u strongswan`。`no trusted public key` は証明書 SAN 不一致 |
| QR が読めない | ターミナルのフォントを小さく／`make show NAME=...` で再表示 |
| DNS が引けない | クライアント設定の `DNS` 行を確認 |

詳しい顛末は [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)、初期セットアップは
[`SETUP.md`](SETUP.md#7-トラブルシューティング) を参照してください。
