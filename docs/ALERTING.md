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

まず送信方式を選ぶ:

1. **外部 SMTP リレー**（Gmail 等）— ユーザー名/パスワード認証あり。
2. **自前 SMTP サーバー** — 認証なし（または対話で任意に認証あり）。

選択に応じて `ALERT_EMAIL` / `SMTP_HOST` / `SMTP_PORT`、認証ありなら `SMTP_USER` /
`SMTP_PASSWORD`、そして `ALERT_BLOCKLIST_URL` を入力すると、SSH でサーバーの env の該当キー
だけを更新し、`setup.sh` の `alerts` モードで監視を冪等に再構成する。**SMTP パスワードは
Terraform state に残らず**、入力値はデータとしてサーバーへ渡す（シェルへ展開しないため
インジェクションも回避）。反映後は `make alerts-test` で送信を確認できる。

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

## 検知の内部動作（watch.sh）

- 状態は `/var/lib/orenovpn/watch/` に保存（`last_run`・`wg_active_peers`・`traffic_bytes`・
  `cooldown/<key>`）。
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
