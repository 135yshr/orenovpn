# 通信監視・警告機能

VPN サーバーで「怪しい通信」を検知し、管理者へメールで警告する機能。既定は無効で、
`enable_traffic_alert = true` と SMTP 設定で有効化する。

## 概要

常駐プロセスを増やさず、監視スクリプト `scripts/watch.sh` を systemd timer で 5 分毎に
実行する「軽量ログ監視型」。フル IDS（Suricata 等）は 512MB プランには重すぎるため採らず、
既存ログとカーネル統計を読むだけに留める。既存の 2 フェーズ構成に乗せている。

```
[フェーズ1 Terraform]  変数追加 → cloud-init が orenovpn.env に監視設定を書く
        ↓
[フェーズ2 setup.sh]   msmtp・監視スクリプト・timer を冪等に構成
        ↓
[定常運用]  watch.sh を 5 分ごとに実行
            → /var/lib/orenovpn/watch に前回スナップショットを保存し差分・閾値を判定
            → 該当があれば msmtp でメール送信（同種はクールダウン 1 時間で抑制）
```

## 検知対象

| 対象 | 手段 | 負荷 |
|------|------|------|
| サーバーへの不審アクセス | `journalctl` の SSH 認証失敗数を集計し閾値判定 | ほぼゼロ |
| 新規 VPN 接続 | `wg show latest-handshakes` / `swanctl --list-sas` を前回と差分 | ほぼゼロ |
| 不審な出口通信 | ipset(`orenovpn_blocklist`) + before.rules の LOG で FORWARD を検知（ログのみ・ドロップしない） | 中 |
| トラフィック量の異常 | 転送バイトの前回比増分を閾値判定 | ほぼゼロ |
| **資格情報の複製** | 同一のピア公開鍵 / 証明書 ID が直近 1 時間に複数の接続元 IP から使われたら警告 | ほぼゼロ |

> 「新規 VPN 接続」は**未知の鍵**しか見ません。設定ファイルやプロファイルを丸ごと
> 複製されると、正規の鍵で接続されるため peer 一覧は増えず、この検知には掛かりません。
> 「資格情報の複製」検知（`ALERT_PEER_IP_THRESHOLD`、既定 3 IP/1時間）がその穴を埋めます。
> 回線切替の多い端末で誤検知が続く場合は、サーバーの `/etc/orenovpn/orenovpn.env` に
> `ALERT_PEER_IP_THRESHOLD="5"` のように書いて閾値を上げてください（`make setup` で
> 上書きされない独立キーです）。

## 設定（terraform.tfvars）

| 変数 | 既定 | 用途 |
|------|------|------|
| `enable_traffic_alert` | `false` | 監視機能全体の ON/OFF |
| `alert_email` | `""` | 通知先メールアドレス |
| `smtp_host` / `smtp_port` / `smtp_user` | `"" / 587 / ""` | msmtp の送信設定 |
| `smtp_password` | `""`（sensitive） | SMTP 認証パスワード |
| `alert_ssh_fail_threshold` | `20` | 1 周期あたり SSH 認証失敗の警告閾値 |
| `alert_traffic_mbytes` | `1024` | 1 周期あたり転送量の警告閾値（MB） |
| `alert_blocklist_url` | `""` | 悪性 IP ブロックリスト取得元（空＝出口検知 OFF） |

設定例（`presets/03-hardened.tfvars` にも実例あり）:

```hcl
enable_traffic_alert = true
alert_email          = "you@example.com"
smtp_host            = "smtp.gmail.com"
smtp_port            = 587
smtp_user            = "you@example.com"
smtp_password        = "アプリパスワード"
```

## 既存サーバーへの反映（make configure-alerts）

上記 `terraform.tfvars` の設定が env（`/etc/orenovpn/orenovpn.env`）に入るのは、**新規デプロイ時**に
cloud-init が env を生成するタイミングだけ。稼働中の既存サーバーでは cloud-init は env を再生成
しないため、tfvars を後から編集しても反映されない（`main.tf` は `ignore_changes = [user_data]`）。

既存サーバーへ後からアラート設定を入れる／変更するときは次を実行する:

```bash
make configure-alerts
```

まず送信方式を選ぶ（3 択）:

1. **外部 SMTP リレー**（Gmail 等）— ユーザー名/パスワード認証あり。
2. **自前 SMTP サーバー** — 認証なし（または対話で任意に認証あり）。
3. **VPN 上のローカル MTA**（`dma`）— **外部 SMTP 不要**。VPS 上の `dma` が宛先 MX へ
   **直接配送**する。**待受ソケットを持たず中継しない**（ローカル投函＝localhost のみ）ため、
   オープンリレーの心配がない。方式③では `ALERT_EMAIL`（通知先）と任意で `MAIL_FROM`
   （差出人・既定は `ALERT_EMAIL`）だけを入力し、`SMTP_HOST` などは不要。

選択に応じて、方式①②では `ALERT_EMAIL` / `SMTP_HOST` / `SMTP_PORT`、認証ありなら
`SMTP_USER` / `SMTP_PASSWORD`、方式③では `ALERT_EMAIL` と任意の `MAIL_FROM`、いずれも
最後に `ALERT_BLOCKLIST_URL` を入力すると、SSH でサーバーの env の該当キーだけを更新し、
`setup.sh` の `alerts` モードで監視を冪等に再構成する。**SMTP パスワードは Terraform state
に残らず**、入力値はデータとしてサーバーへ渡す（シェルへ展開しないためインジェクションも
回避）。反映後は `make alerts-test` で送信を確認できる。

送信方式は env の `SMTP_MODE`（`relay` = 外部/自前 SMTP へ msmtp でリレー／`local` = VPN 上の
`dma` で直接配送）で制御される。方式③（`SMTP_MODE=local`）は**待受ソケットを持たず中継
できない**が、直接配送はメールの到達性が受信側のスパム判定に左右されるため、**DNS 逆引き
（PTR）と SPF（可能なら DKIM）の設定を推奨**する（ConoHa のコントロールパネルで PTR を設定）。

認証の有無は env の `SMTP_AUTH`（`on` = 認証あり／`off` = 認証なし）で制御され、`setup.sh` は
`SMTP_AUTH=off` のとき `/etc/msmtprc` を認証なしで生成する。自前 SMTP は **STARTTLS 既定**の
ため、平文（暗号化なし）のみ受け付けるサーバーでは反映後に `/etc/msmtprc` の `tls off` を
手動で調整する必要がある場合がある。

## 運用コマンド

| コマンド | 内容 |
|----------|------|
| `make configure-alerts` | 既存サーバーへアラート設定を反映（対話入力・state に残さない） |
| `make alerts-test` | テスト通知メールを送信して SMTP 設定を確認 |
| `make alerts-status` | 監視 timer の稼働状況と直近ログを表示 |
| `make doctor` | 監視 timer・スクリプト・msmtp 設定の点検を含む自己診断 |

## セキュリティ上の注意

- **SMTP パスワードは Terraform state と `/etc/orenovpn/orenovpn.env`（0600）に平文で残る。**
  - 送信専用アカウントやアプリパスワード（Gmail 等）を使い、被害を局所化する。
  - state に残したくない場合は、env に置かず `make setup` 後にサーバー上で `/etc/msmtprc` を
    手動設定する運用も可能（`watch.sh` は `/etc/msmtprc` を参照する）。
- 出口通信検知は既定で**ログのみ**（ドロップしない）。誤検知による VPN 不安定化を避けるため。

## アクセス先の記録（宛先IP / ドメイン名）

監視・警告とは別に、**「いつ・どの端末が・どこへ接続したか」を残す**機能です。既定は OFF。
不正利用や踏み台化の事後調査には、警告だけでなくこの証跡が必要になります。

### 何が記録できて、何ができないか

| 記録できるもの | 手段 | 前提・限界 |
|---|---|---|
| 宛先 IP・ポート・接続元の VPN 内 IP・時刻 | `nat PREROUTING` の `LOG`（新規接続ごとに 1 行）→ カーネルログ → journald | 確実。プロトコルに関係なく残る |
| ドメイン名 | サーバー上の `unbound` の query log | 端末が **DoH/DoT（暗号化 DNS）を使うと迂回**され記録されない |
| HTTPS のホスト名（SNI） | — | **未実装（将来課題）**。下記参照 |
| 完全な URL（パス・クエリ） | — | **不可**。TLS で暗号化されており、復号（MITM）なしには取得できない |

### 設定

| 変数 | 既定 | 用途 |
|------|------|------|
| `enable_access_log` | `false` | 宛先 IP/ポートの記録 |
| `enable_dns_logging` | `false` | 自前リゾルバ(unbound)でドメイン名を記録 |
| `log_retention_days` | `14` | 保存日数（journald の `MaxRetentionSec`。併せて `SystemMaxUse=1G`）|

既存サーバーには tfvars の変更が届かない（cloud-init は初回のみ）ため、専用コマンドで反映します:

```bash
make configure-logging ACCESS_LOG=on DNS_LOG=on DAYS=14   # 有効化して setup.sh を再実行
make configure-logging ACCESS_LOG=off DNS_LOG=off         # 無効化（ルールも撤去）
make logs-status                                          # 有効/無効・適用ルール・待受を確認
```

### 参照

```bash
make access-log            # 宛先IP/ポートの直近と、宛先ごとの集計（上位20）
make dns-log HOURS=24      # DNS 問い合わせの直近と、名前ごとの集計（上位20）
```

出力例（`make access-log`）:

```
== 宛先ごとの接続数（上位 20 / 過去 6 時間）==
     2  93.184.216.34:443       from 10.66.66.2
     2  198.51.100.5:6667       from 10.66.66.9      ← 見慣れないポートへ繰り返し接続
```

接続元は VPN 内アドレス（`10.66.66.x`）なので、どの端末かは `make clients` の割当と対応します。

### 実装上の要点（変更するときの注意）

- **記録ルールは `nat PREROUTING` に置く**。`FORWARD` や ufw の `ufw-before-forward` に置くと
  **WireGuard では一切発火しない**（`wg0.conf` の PostUp が FORWARD の先頭で ACCEPT するため
  ufw のチェーンに到達しない）。`nat PREROUTING` は FORWARD より前で、かつ新規接続の
  最初のパケットだけが通るので「1 接続 1 行」になる。
- ルールは `orenovpn-fwlog.service`（oneshot・check-then-add で冪等）が適用する。
  `before.rules` に書くと `ufw reload` が noflush で再適用して**二重登録**になるため。
- **DNS は素の 53 番を DNAT で自前リゾルバへ強制**するので、クライアント設定を作り直さなくても
  記録されます（IKEv2 は配布 DNS 自体もサーバーに切り替わり、再接続で反映）。
- **unbound は VPN 内アドレスと localhost にしか待受しない**（`access-control` でも VPN
  サブネットのみ許可）。外部に開くとオープンリゾルバ＝増幅攻撃の踏み台になる。
  `make doctor` が待受アドレスを検査して全アドレス待受を FAIL にします。
- unbound が起動できない場合、**DNAT は入れません**（記録より名前解決の維持を優先）。

### プライバシーと運用

- 記録されるのは接続先です。自分専用ならただの証跡ですが、**家族・同僚など他人の端末も
  接続している場合は、閲覧履歴に相当する情報が残る**ことを伝えてから有効化してください。
- 量は端末あたり 1 日 1〜10MB 程度。`log_retention_days` と journald の 1G 上限で頭打ちになります。

### 将来課題: SNI の記録

DoH/DoT を使う端末ではドメイン名が残りません。TLS の ClientHello から SNI を抽出すれば
名前を取れますが、常駐のパケット解析（`ulogd2` / `suricata` / `zeek` 等）が必要で
512MB プランでは負荷が見合いません。上位プラン前提のオプトインとして別途検討します。
なお ECH（Encrypted ClientHello）が普及すると SNI も見えなくなるため、恒久的な手段では
ありません（宛先 IP の記録だけは常に有効です）。

## 検知の内部動作（watch.sh）

- 状態は `/var/lib/orenovpn/watch/` に保存（`last_run`・`wg_active_peers`・`traffic_bytes`・
  `identity_ips`・`cooldown/<key>`）。
- 資格情報の複製検知は `identity_ips` に `時刻<TAB>識別子<TAB>接続元IP` を蓄積し、
  1 時間より古い行を毎回捨てて「同一識別子あたりの異なる IP 数」を数える。識別子は
  WireGuard がピア公開鍵、IKEv2 が証明書の ID（`swanctl --list-sas` の `remote '...'`）。
- 各検知は独立し、1 つが失敗しても他は継続する。
- 同種アラートは 1 時間クールダウン（`cooldown/<key>` の mtime で判定）し、5 分周期で同じ
  警告を送り続けない。
- 監視期間は前回実行時刻（`last_run`）から現在まで。初回は「5 分前から」。

## 段階的導入

1. 軽量ログ監視 + メール通知（SSH 失敗・新規接続・トラフィック量）— **実装済み**。
   `enable_traffic_alert = true` と SMTP 設定で作動する。
2. 出口通信検知 — **実装済み**。`alert_blocklist_url` に悪性 IP リストの URL を設定すると、
   段階1 の監視に加えて出口通信の検知が作動する。仕組みは次の通り:
   - ipset `orenovpn_blocklist`（`hash:net`）に悪性 IP/CIDR を取り込み、
     `orenovpn-egress-refresh.timer`（daily）で自動更新する。
   - ufw の `/etc/ufw/before.rules`（`ufw-before-forward` 鎖）に LOG ルールを冪等に追記する
     （**ログのみ・ドロップはしない**）。
   - `watch.sh` が `journalctl -k` の `orenovpn-egress:` 行を集計してメール通知する。
   - 起動時は `orenovpn-ipset-restore.service`（`Before=ufw.service`）で ipset を ufw より先に
     復元し、ルールと ipset の整合を保つ。
