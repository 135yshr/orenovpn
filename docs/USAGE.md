# 使い方ガイド

デプロイ後の日常的な使い方（各デバイスからの接続・クライアント管理）をまとめます。
初回セットアップは [`SETUP.md`](SETUP.md)、セキュリティ設定は [`SECURITY.md`](SECURITY.md) を参照してください。

## 目次

- [クライアント管理コマンド](#クライアント管理コマンド)
- [iPhone / iPad から接続](#iphone--ipad-から接続)
- [Android から接続](#android-から接続)
- [Mac / Windows / Linux から接続](#mac--windows--linux-から接続)
- [接続状態の確認](#接続状態の確認)
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

> `NAME` は英数字・ハイフン・アンダースコアのみ。デバイスごとに別名を付けます
> （例: `iphone`, `ipad`, `macbook`, `work-pc`）。**同じ設定を複数端末で使い回さない**でください。

> 💡 SSH 鍵を既定以外のパスに作った場合は、各コマンドに `SSH_KEY=` を付けます。
> 例: `make client NAME=iphone SSH_KEY=~/.ssh/orenovpn`
> （`~/.ssh/config` に書いておけば指定不要。詳細は [SETUP.md](SETUP.md#1-3-ssh-鍵ペアを作成)）

---

## iPhone / iPad から接続

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

# サーバーから設定ファイルを取得（ポートは ssh_port に合わせる）
scp -P 22022 vpnadmin@<サーバーIP>:/etc/orenovpn/clients/macbook.conf ./
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

---

## よくある操作

### 新しいデバイスを追加する

```bash
make client NAME=<好きな名前>
```

### デバイスを紛失した / 接続を無効化したい

該当クライアントを削除すれば即座に接続できなくなります。

```bash
make remove NAME=<該当クライアント>
```

### つながらないとき

| 症状 | 確認 |
|------|------|
| ハンドシェイクしない | ConoHa 側で `wg_port`(UDP) が開いているか、`make clients` でサーバー稼働を確認 |
| 接続はするが通信できない | `make ssh` → `sudo wg show` と `sudo cat /var/log/orenovpn-setup.log` |
| QR が読めない | ターミナルのフォントを小さく／`make show NAME=...` で再表示 |
| DNS が引けない | クライアント設定の `DNS` 行を確認（既定 `1.1.1.1,1.0.0.1`）|

詳しいトラブルシューティングは [`SETUP.md`](SETUP.md#7-トラブルシューティング) を参照してください。
