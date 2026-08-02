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
| **SSH ログイン成功** | `journalctl` の `Accepted ...` 行を前回実行時刻から拾い、成立したログインを毎回通知（既定 ON）| ほぼゼロ |
| 新規 VPN 接続 | `wg show latest-handshakes` / `swanctl --list-sas` を前回と差分。接続が 0 件の状態も記録するため「未接続 → 接続」の遷移で通知される（1セッション1通・同種は1時間クールダウン）。IKEv2 は **`ESTABLISHED`（＝クライアント証明書の検証まで通った）SA の `remote` 行だけ**を数える | ほぼゼロ |
| 不審な出口通信 | ipset(`orenovpn_blocklist`) + `nat PREROUTING` の LOG で検知（ログのみ・ドロップしない）。**`-s <VPN サブネット>` で VPN 発に限定**し、リスト側も VPN サブネットを `nomatch` で除外する（公開リストは private 範囲を含むため、限定しないと戻り通信が全件一致して誤検知になる）| 中 |
| トラフィック量の異常 | 転送バイトの前回比増分を閾値判定。WireGuard は `wg show transfer`、IKEv2 は `swanctl --list-sas` の CHILD_SA 転送量を合算（policy ベースの IPsec には `ipsec0` のようなインターフェイスが無いため）| ほぼゼロ |
| **資格情報の複製** | 同一のピア公開鍵 / 証明書 ID が直近 1 時間に複数の接続元 IP から使われたら警告 | ほぼゼロ |
| **クライアントの作成/削除** | `vpn-client add` / `remove` が実行された時点で即時通知（5 分周期ではない）。実行者・接続元 IP・鍵/証明書の識別子を載せる。削除側は IKEv2 の失効(CRL)に成功したかも含む | ほぼゼロ |

> 「クライアントの作成/削除」は**サーバー上で鍵が発行された瞬間**を捉えます。接続の検知
> （新規 VPN 接続・資格情報の複製）は「発行済みの鍵が使われた」後にしか鳴りませんが、
> root を取られた場合、攻撃者はまず**自分用の正規の鍵を発行**して居座ります。その鍵で
> 接続されても「正規のクライアント」にしか見えないため、接続側の検知では気付けません。
> 作成イベントの通知がその穴を埋めます（`make client` を実行していないのに
> 「VPN クライアントを作成」が届いたら、サーバーが侵害されています）。
>
> IKEv2 で「認証前の SA」を数えてはいけません。`swanctl --list-sas` は IKE_SA_INIT に
> 応答しただけの半開き SA も `CONNECTING` として列挙し、相手の身元は `remote '%any'` の
> ままです。UDP/500 を叩くだけのポートスキャナで作られるため、これを数えると
> **接続されていないのに「IKE_SA が確立されました」と通知される**（→ TROUBLESHOOTING #25）。
>
> 「新規 VPN 接続」は**未知の鍵**しか見ません。設定ファイルやプロファイルを丸ごと
> 複製されると、正規の鍵で接続されるため peer 一覧は増えず、この検知には掛かりません。
> 「資格情報の複製」検知（`ALERT_PEER_IP_THRESHOLD`、既定 3 IP/1時間）がその穴を埋めます。
> 回線切替の多い端末で誤検知が続く場合は、サーバーの `/etc/orenovpn/orenovpn.env` に
> `ALERT_PEER_IP_THRESHOLD="5"` のように書いて閾値を上げてください（`make setup` で
> 上書きされない独立キーです）。

## SSH ログイン成功の通知

サーバー本体へ **SSH ログインが成功するたび**にメールが届きます（VPN への接続ではなく、
管理者としてのログイン）。既定 ON で、`enable_traffic_alert = true`（＝監視機能全体）が
前提です。

**なぜ「失敗の急増」だけでは足りないか**: `alert_ssh_fail_threshold` が捉えるのは総当たりだけ
です。SSH 秘密鍵が漏れた場合の侵入は**一発で成功する**ため認証失敗が 1 件も出ず、失敗側の
監視には一切掛かりません。成功したログインの通知が、この経路に対する唯一の検知です。

メール本文には時刻・ユーザー名・接続元 IP・接続元ポート・認証方式・鍵のフィンガープリント
（`journalctl` の `Accepted` 行に出る範囲）が入ります。

```text
Subject: [orenovpn] SSH ログイン成功を検知（1 件）

  2026-07-26T12:34:56+0900  admin@203.0.113.5:54321  publickey ssh2: ED25519 SHA256:AbCd/efg
```

### 動作の性質（承知しておくこと）

- **最大 5 分遅れる**。監視 timer の周期でまとめて送るため、即時通知ではありません。
- **自分の作業でも届く**。`make setup` / `make client` / `make doctor` など SSH を使う操作は
  すべてログインなので通知されます。固定 IP から作業しているなら
  `alert_ssh_login_ignore_ips`（サーバー側は `ALERT_SSH_LOGIN_IGNORE_IPS`）で除外できます。
- **1 周期分をまとめて 1 通**。他のアラートと違い 1 時間クールダウンは掛けません（掛けると
  2 回目以降のログインを取りこぼすため）。送信は 5 分あたり最大 1 通、本文の明細は 20 件
  までで、超過分は「ほか N 件」と件数だけ示します。
- 通知済みのログインは 1 時間ぶん `/var/lib/orenovpn/watch/ssh_logins_seen` に記録し、監視期間
  の端が重なっても二重通知しません。

### なぜ PAM（即時通知）ではないか

`pam_exec` で SSH ログインの瞬間にメールを送る方式もありますが、**メール送信の遅延や失敗が
SSH ログイン自体を遅延・失敗させうる**ため採用していません。SMTP が詰まったときに管理者が
サーバーへ入れなくなる（＝復旧手段を失う）リスクは、通知が最大 5 分遅れる不便より重いという
判断です。

### 通知を止める / 除外する

```bash
make configure-alerts          # 対話で ON/OFF と除外 IP を設定（既存サーバー向け）
```

サーバー上で直接変える場合は `/etc/orenovpn/orenovpn.env` を編集します（`make setup` では
上書きされない独立キーです）。

```bash
ENABLE_SSH_LOGIN_ALERT="false"                       # 通知を止める
ALERT_SSH_LOGIN_IGNORE_IPS="203.0.113.5 198.51.100.9" # 特定の接続元だけ除外
```

## 設定（terraform.tfvars）

| 変数 | 既定 | 用途 |
|------|------|------|
| `enable_traffic_alert` | `false` | 監視機能全体の ON/OFF |
| `alert_email` | `""` | 通知先メールアドレス |
| `smtp_host` / `smtp_port` / `smtp_user` | `"" / 587 / ""` | msmtp の送信設定 |
| `smtp_password` | `""`（sensitive） | SMTP 認証パスワード |
| `smtp_mode` | `"relay"` | `"relay"`=外部 SMTP へ msmtp でリレー / `"local"`=VPN 上の `dma` が宛先 MX へ直接配送（外部 SMTP 不要・待受なし）|
| `mail_from` | `""` | 差出人（`relay` / `local` の両モードで有効。優先順位は `mail_from` → `smtp_user` → `alert_email`）。**`local` モードでは自分が管理するドメインのアドレスを必ず指定**（受信側アドレスを差出人にすると SPF 違反で拒否される）。`relay` モードで認証付きリレー（Gmail 等）を使う場合は、そのアカウントで送信が許可されたアドレスにすること（不一致だとリレーに拒否される）|
| `alert_ssh_fail_threshold` | `20` | 1 周期あたり SSH 認証失敗の警告閾値 |
| `enable_ssh_login_alert` | `true` | SSH ログイン**成功**の通知 |
| `alert_ssh_login_ignore_ips` | `[]` | ログイン通知から除外する接続元 IP（完全一致） |
| `enable_client_change_alert` | `true` | VPN クライアント（プロファイル）の**作成・削除**の通知 |
| `alert_traffic_mbytes` | `1024` | 1 周期あたり転送量の警告閾値（MB） |
| `alert_blocklist_url` | `""` | 悪性 IP ブロックリスト取得元（空＝出口検知 OFF） |

設定例（`presets/03-hardened.tfvars` にも実例あり）:

```hcl
# 外部 SMTP リレー（到達性が確実）
enable_traffic_alert = true
alert_email          = "you@example.com"
smtp_host            = "smtp.gmail.com"
smtp_port            = 587
smtp_user            = "you@example.com"
smtp_password        = "アプリパスワード"
```

```hcl
# VPN 上のローカル MTA（外部 SMTP 不要。dma が宛先 MX へ直接配送）
enable_traffic_alert = true
alert_email          = "you@example.com"
smtp_mode            = "local"
mail_from            = "orenovpn@vpn.example.com" # ★自分が管理するドメイン
```

**`local` モードの到達性には3つの前提があります。** どれか欠けるとメールは届きません。

1. **外向き 25 番が使えること**（プロバイダが制限している場合がある）。確認:
   `timeout 5 bash -c 'exec 3<>/dev/tcp/gmail-smtp-in.l.google.com/25 && head -1 <&3'`
2. **逆引き(PTR)** … ConoHa のコントロールパネルで VPS の IP に FQDN を設定し、
   サーバーのホスト名も合わせる（`hostnamectl set-hostname vpn.example.com` → `make setup`）
3. **SPF** … `mail_from` のドメインに `"v=spf1 ip4:<VPSのIP> -all"` を公開する
   （`dma` は DKIM 非対応のため、PTR と SPF で担保する）

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
最後に SSH ログイン通知の ON/OFF（既定 ON）・除外 IP と `ALERT_BLOCKLIST_URL` を入力すると、SSH でサーバーの env の該当キーだけを更新し、
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
| `make doctor` | 監視 timer・スクリプト・msmtp 設定・MCP 用鍵の点検を含む自己診断 |
| `sudo orenovpn-logs egress [時間]` | 出口検知（既知悪性 IP への通信）の一覧と集計 |
| `sudo orenovpn-logs blocklist <IP>` | その IP がブロックリストのどの範囲で一致したか |
| `sudo orenovpn-logs clients` | 登録済みクライアントと VPN 内アドレスの対応 |

## アラートを受け取った後の分析（orenovpn-mcp）

メールは「何かが起きた」までしか伝えない。**その後の絞り込みはサーバー上のログを読む**
必要がある。手作業なら次の順で追える。

```bash
make ssh                                        # サーバーへ入る
sudo orenovpn-logs egress 24                    # 出口検知の宛先と接続元
sudo orenovpn-logs blocklist 185.220.101.1      # その宛先がどの範囲で一致したか
sudo orenovpn-logs clients                      # 接続元の VPN 内 IP からクライアント名を引く
sudo orenovpn-logs access 24                    # 全端末の宛先（接続元の列で見分ける）
sudo orenovpn-logs dns 24                       # 全端末の DNS 問い合わせ（名前）
```

**接続元での絞り込みは `--json` を付けたときだけ**。人間向けの `access` / `dns` は
第 1 引数を時間として扱うため、`orenovpn-logs access 10.66.66.2 24` は
「時間は整数で指定してください」で終わる。端末を 1 台に絞るならこう:

```bash
sudo orenovpn-logs access --json 10.66.66.2 24 | jq .
sudo orenovpn-logs dns    --json 10.66.66.2 24 | jq -r '.queries[] | "\(.at) \(.name)"'
```

この一連の絞り込みを AI に任せるための口が
[135yshr/orenovpn-mcp](https://github.com/135yshr/orenovpn-mcp)（読み取り専用の MCP サーバー）。
上のコマンドと同じ `orenovpn-logs` を、SSH の forced command 越しに **JSON で**読む。
新しい経路を増やしているのではなく、既存のコマンドに `--json` を足しただけなので、
MCP が壊れても `make access-log` は今までどおり動く。

### MCP 用の SSH 鍵を作って登録する

**`admin` の鍵を流用しないこと。** `admin` は NOPASSWD sudo を持つため、
ログを読ませるためにサーバーの管理権限ごと渡すことになる。専用の鍵を作り、
`command=` で読み取り 6 コマンドだけに縛る。

```bash
# 1) 手元で MCP 専用の鍵を作る（パスフレーズなし。非対話で使うため）
ssh-keygen -t ed25519 -f ~/.ssh/orenovpn-mcp -C orenovpn-mcp -N ''
chmod 600 ~/.ssh/orenovpn-mcp

# 2) 接続先を控える（以降の手順で使う）
HOST="$(terraform -chdir=terraform output -raw server_ip)"
USER="$(terraform -chdir=terraform output -raw admin_user)"

# 3) ディスパッチャがサーバーに入っていることを確認（make setup / sync-scripts で配置される）
ssh "${USER}@${HOST}" 'ls -l /usr/local/sbin/orenovpn-mcp-shell'

# 4) 公開鍵を authorized_keys へ「必ず command= と restrict 付きで」追記する
#    すべて手元で実行し、鍵の中身は標準入力で渡す（サーバー側のシェルで変数を
#    展開させない。ログインしてから echo "... ${KEY}" と打つと KEY はサーバー側で
#    未定義になり、鍵本体の入っていない不正な行が追記される）。
{ printf 'command="/usr/local/sbin/orenovpn-mcp-shell",restrict '
  cat ~/.ssh/orenovpn-mcp.pub
} | ssh "${USER}@${HOST}" 'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys'

# 5) 追記された行を目視で確認する（オプションが行頭にあること）
ssh "${USER}@${HOST}" 'tail -1 ~/.ssh/authorized_keys'

# 6) ホスト鍵の指紋を控える（MCP 側は StrictHostKeyChecking=no を持たない）
ssh-keyscan -t ed25519 "$HOST" | ssh-keygen -lf -

# 7) 点検（command=/restrict の付け忘れとディスパッチャの配置を検査する）
make doctor
```

**オプションは必ず鍵種別（`ssh-ed25519`）より前に書く。** 後ろに書いたものは
sshd から見ればただの鍵コメントで、制限は一切かからない（＝全権の鍵になる）。
正しい行はこの形:

```
command="/usr/local/sbin/orenovpn-mcp-shell",restrict ssh-ed25519 AAAA... orenovpn-mcp
```

鍵コメントの `orenovpn-mcp` は `make doctor` が「MCP 用の鍵」を識別する目印なので消さない。
`restrict` は `no-agent-forwarding` / `no-port-forwarding` / `no-pty` / `no-user-rc` /
`no-X11-forwarding` をまとめて有効にする（OpenSSH 7.2 以降）。個別指定ではなく `restrict` を
使うのは、将来 OpenSSH にオプションが増えても自動で追随させるため。

動作確認（クライアント一覧が返り、それ以外は終了コードだけが返る）:

```bash
ssh -i ~/.ssh/orenovpn-mcp <admin_user>@<server_ip> clients   # JSON が返る
ssh -i ~/.ssh/orenovpn-mcp <admin_user>@<server_ip> 'rm -rf /'  # 何も起きず exit 1
ssh -i ~/.ssh/orenovpn-mcp <admin_user>@<server_ip> 'clients; id'  # 同上
```

### 何を読めるようになるか（境界）

| `$SSH_ORIGINAL_COMMAND` | 実行されるもの |
|---|---|
| `egress <時間> <件数>` | `orenovpn-logs egress --json` |
| `access <接続元IP> <時間>` | `orenovpn-logs access --json` |
| `dns <接続元IP> <時間>` | `orenovpn-logs dns --json`（`0.0.0.0` は全接続元） |
| `clients` | `orenovpn-logs clients --json` |
| `blocklist <IP>` | `orenovpn-logs blocklist --json` |
| `status` | `orenovpn-logs status --json` |

**これで全部**であり、書き込み系（削除・失効・設定変更）は許可リストに入っていない。
鍵が漏れても、AI が誤った判断をしても、この鍵では構成は壊れない。対処が必要なときは
人が `make remove NAME=x` を実行する。

`clients` の JSON に `PrivateKey` / `PresharedKey` は**含まれない**。分析に不要であり、
返した瞬間に会話ログと AI の文脈へ資格情報が流れるため。

呼び出しは journal に記録される（誰がいつ何を読んだか）:

```bash
sudo journalctl -t orenovpn-mcp-shell -n 50
```

**ログの中身は「読ませる相手」に届くデータであることを忘れないこと。** VPN を家族や同僚に
配っているなら、その人たちの閲覧履歴（宛先 IP・問い合わせたドメイン名）が MCP を通じて
AI の文脈に流れる。ローカルの stdio 接続なら手元で完結するが、HTTP コネクタとして公開すると
経路が変わる。詳細は orenovpn-mcp の `docs/SECURITY.md`。

## セキュリティ上の注意

- **MCP 用の鍵には必ず `command=` と `restrict` を付ける**（上記）。付け忘れると
  「ログを読む鍵」ではなく「NOPASSWD sudo を持つサーバーの全権の鍵」になる。
  `make doctor` がこの退行を検出する。
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

```text
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
- `ufw reset` / `ufw disable`→`enable` のように**組み込みチェーンが作り直される操作**の後は、
  記録ルールが失われることがあります。`make doctor` が「宛先記録ルール」「出口 LOG ルール」
  「DNS 強制転送(DNAT)」の欠落を検出するので、指摘されたら次で再適用してください:
  `sudo systemctl restart orenovpn-fwlog`（`make setup` の再実行でも復旧します）。

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
  `identity_ips`・`ssh_logins_seen`・`cooldown/<key>`）。
- SSH ログイン成功の検知は `journalctl -u ssh -u sshd -o short-iso` の `Accepted <方式> for
  <ユーザー> from <IP> port <ポート>` を拾い、`時刻|ユーザー|IP|ポート` を鍵に
  `ssh_logins_seen`（1 時間で失効）と突き合わせて未通知分だけを 1 通にまとめる。
- 資格情報の複製検知は `identity_ips` に `時刻<TAB>識別子<TAB>接続元IP` を蓄積し、
  1 時間より古い行を毎回捨てて「同一識別子あたりの異なる IP 数」を数える。識別子は
  WireGuard がピア公開鍵、IKEv2 が証明書の ID（`swanctl --list-sas` の `remote '...'`）。
- 各検知は独立し、1 つが失敗しても他は継続する。
- 同種アラートは 1 時間クールダウン（`cooldown/<key>` の mtime で判定）し、5 分周期で同じ
  警告を送り続けない。
- 監視期間は前回実行時刻（`last_run`）から現在まで。初回は「5 分前から」。

## 段階的導入

1. 軽量ログ監視 + メール通知（SSH 失敗・SSH ログイン成功・新規接続・トラフィック量）— **実装済み**。
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
