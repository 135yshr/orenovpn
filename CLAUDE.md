# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 何をするリポジトリか

ConoHa VPS Ver.3.0（OpenStack 準拠 API）上に個人用 VPN を構築する **Terraform + シェルスクリプトのテンプレート**。VPN は **WireGuard**（既定）と **IKEv2/IPsec**（iPhone/macOS 標準・アプリ不要）を `vpn_protocol` で切り替える。アプリケーションコードはなく、成果物は IaC・プロビジョニングスクリプト・ドキュメント。ドキュメントは日本語で書く。

## よく使うコマンド

すべて `make`（`Makefile`）が入口。`terraform` は `terraform -chdir=terraform` にラップされている。

```bash
make check          # デプロイ前のローカル一括検証（fmt -check / validate / bash -n / shellcheck）。CI と同じ内容
make fmt            # terraform fmt -recursive
make preset PRESET=balanced   # プリセットを terraform.tfvars にコピー（simple|balanced|hardened|ikev2）
make init && make deploy      # フェーズ1: VPS 作成（terraform init / apply）
make setup          # フェーズ2: スクリプトを SSH 転送し setup.sh を sudo 実行（VPN 構成）
make sync-scripts   # サーバー上のスクリプトだけ更新（setup.sh は実行しない・修正の反映に使う）
make doctor         # サーバー構成の自己診断（scripts/doctor.sh をリモート実行）
make client NAME=x  # クライアント追加。make clients / show / remove も同様
make access-log     # 記録した接続先(宛先IP)を表示。make dns-log / logs-status も同様
make configure-logging ACCESS_LOG=on DNS_LOG=on  # 既存サーバーの記録機能を ON/OFF
make images FILTER=debian   # 利用可能な OS イメージ名を確認（image_name 設定の前に）
```

- **コミット前は必ず `make check`** を通す。これが CI（`.github/workflows/ci.yml`）と同一の検証（shellcheck `-S warning` / `bash -n` / `terraform fmt -check` / `terraform validate`）。
- テストフレームワークは無い。検証＝静的解析（上記）と、実機に対する `make doctor`。
- `shellcheck` 未導入なら `make check` はスキップするが、CI では必須。ローカルにも入れておくこと。

## アーキテクチャ（2 フェーズ構成が要）

このプロジェクトの中心的な設計は **プロビジョニングを 2 フェーズに分離** している点。ここを理解しないと変更を誤る。

- **フェーズ1（Terraform / `terraform/`）**: VPS・ボリューム・セキュリティグループ・SSH 鍵を作成し、**最小限の cloud-init** だけ流す。cloud-init（`templates/cloud-init.yaml.tftpl`）は VPN 本体を構成せず、`admin_user` 作成・SSH 堅牢化・`/etc/orenovpn/orenovpn.env` 生成にとどめる。user_data を小さく保ち初回ブートを速く確実にするため。
- **フェーズ2（`scripts/setup.sh`）**: `make setup` が `scripts/` を SSH 転送して `/usr/local/sbin/` に install し、`setup.sh` を sudo 実行。ここで WireGuard / strongSwan・ufw・NAT・fail2ban・初期クライアントを構成する。**冪等で何度でも再実行可能**。設定値は cloud-init が書いた `orenovpn.env` から読む。
- `main.tf` は `lifecycle { ignore_changes = [user_data] }`。**構成変更は Terraform ではなくサーバー上のスクリプトで行う運用**。tfvars を変えても既存 VPS の VPN 構成は変わらない（`make setup` の再実行で反映）。

### スクリプトの分担（`scripts/`）
- `vpn-client`: ディスパッチャ。`VPN_PROTOCOL` を見て `wg-client` か `ikev2-client` に委譲する薄いラッパ。`make client/show/remove` はこれを叩く。
- `wg-client` / `ikev2-client`: プロトコル別のクライアント add/list/show/remove の実体。
- `setup.sh`: フェーズ2 の本体。
- `serve-profile.sh`: `make serve-profile` の実体。VPS 上で一時 HTTPS + QR を立て iPhone に `.mobileconfig` を配布（Let's Encrypt 証明書使用）。
- `list-images.sh` / `list-volume-types.sh`: ConoHa の有効な名前を照会するヘルパ。
- `doctor.sh`: リモートで実行される診断。構成の退行検出もここに集約する（新しい不変条件を作ったら必ず検査を足す）。
- `watch.sh`: 通信監視・警告の本体。`/usr/local/sbin/orenovpn-watch` として install され systemd timer が 5 分毎に実行。
- `orenovpn-logs`: 記録したアクセス先（宛先IP / DNS）の表示・集計。`make access-log` / `dns-log` / `logs-status` の実体。`--json` を付けると機械可読な出力になる（orenovpn-mcp 用。人間向けの整形出力は絶対に変えない）。
- `orenovpn-mcp-shell`: orenovpn-mcp（読み取り専用 MCP サーバー）用の forced command ディスパッチャ。`$SSH_ORIGINAL_COMMAND` を許可リスト 6 コマンドと突き合わせて `orenovpn-logs --json` に振り分ける。
- `configure-alerts.sh` / `configure-logging.sh`: 既存サーバーの `orenovpn.env` を SSH で更新して設定を反映する（cloud-init は初回のみ動くため、tfvars の変更は既存 VPS に届かない）。

### Terraform ファイル構成（`terraform/`）
- `main.tf` インスタンス／ボリューム／鍵、`security.tf` セキュリティグループ、`variables.tf` 全変数（多くにデフォルトあり）、`outputs.tf`（`server_ip` / `admin_user` 等を Makefile が参照）、`providers.tf` / `versions.tf`。
- `presets/*.tfvars` が `make preset` のコピー元。`terraform.tfvars` は各自の秘密情報（gitignore 済み）。

## この環境固有の落とし穴（変更時に踏みやすい）

- **セキュリティグループのルールはインスタンス作成時に宣言しておく必要がある**。ConoHa は稼働中インスタンスに後から追加した SG ルールを反映しない。配信ポート等を後から開こうとしても効かない（`enable_profile_download` / `profile_port` が作成時に SG を決めているのはこのため）。
- **`config_drive = true` は必須**。ConoHa では metadata サービス経由の user_data が cloud-init に適用されないことがあり、config-drive で確実に処理させている。
- **サーバー内のファイアウォールは ufw に一本化**。`setup.sh` は Debian 既定の nftables を `systemctl disable --now` で無効化する（`table inet filter` の input policy drop が ufw より優先し VPN ポートを落とすため）。ファイアウォール周りを触るときはこの前提を崩さない。
- **転送(FORWARD)を広く許可してはいけない**（セキュリティ不変条件）。`DEFAULT_FORWARD_POLICY` は必ず `DROP`、MASQUERADE には必ず `-s <VPN サブネット>`、FORWARD の許可は向き（`-i wg0 -o <WAN>`／`-m policy --pol ipsec`／確立済みの戻り）まで限定する。過去に `-o wg0 -j ACCEPT` と `DEFAULT_FORWARD_POLICY=ACCEPT` を使っていたため、**VPN 認証なしで外部からトンネル内へ到達でき、サーバーが第三者通信の中継にもなっていた**。`make doctor` がこの退行を検出する。
- **`serve-profile.sh` の配信ハンドラに `SimpleHTTPRequestHandler` を使ってはいけない**（セキュリティ不変条件）。index の無いディレクトリに autoindex を返すため、「推測不能な URL トークン」が列挙され防御が消える。配布物は VPN 資格情報そのもの（IKEv2 の `.mobileconfig` は p12 の復号パスワードを平文で含む）なので、トークン完全一致・Host 一致・回数上限・時間上限・サーバー側 watchdog による強制クローズ・`/var/log/orenovpn-serve.log` への記録をすべて維持する。`/tmp` へ配布物を複製しない（root 専有パスから直接読む）。
- **アクセス先の記録ルールは `nat PREROUTING` に置く**（`FORWARD` や `ufw-before-forward` ではない）。WireGuard は `wg0.conf` の PostUp が FORWARD 先頭で ACCEPT するため、ufw のチェーンにパケットが到達せず**ログが一切出ない**（既存の出口ブロックリスト検知が WireGuard で発火しないのはこれが理由）。ルールの適用は `orenovpn-fwlog.service`（check-then-add で冪等）が担う。`before.rules` に書くと `ufw reload` が noflush で再適用して二重登録になる。
- **DNS 記録の `unbound` は VPN 内アドレスと localhost にしか待受させない**（`access-control` でも VPN サブネットのみ許可）。外部に開くとオープンリゾルバ＝増幅攻撃の踏み台になる。また unbound が動いていないときは DNS の DNAT を入れない（記録より名前解決の維持を優先）。
- **IKEv2 の証明書失効(CRL)は既定 ON**（`enable_cert_revocation = true`）。OFF にすると `make remove` が「ファイル削除だけ」になり、漏洩した証明書を 10 年間止められない。`ikev2-client remove` は失効できなかった場合に証明書の原本を**残す**（消すと将来も失効できなくなる）。
- **`make setup` は VPN を切断した状態で実行する**。途中で strongSwan / wg-quick を再起動するため、VPN 経由の SSH（フルトンネルなのでサーバーへの SSH もトンネル内を通る）だと接続ごと切れて構成が中断する。setup.sh は `SSH_CONNECTION` の接続元が VPN サブネット内なら実行を拒否する（`ORENOVPN_ALLOW_VPN_SETUP=1` で上書き可）。
- **SSH は 22 番固定**（Debian の SSH ソケットアクティベーションでポート変更が反映されず接続不能になり得るため機能として持たない）。防御は鍵認証＋fail2ban＋`allowed_ssh_cidr`。
- **`orenovpn-mcp-shell` が MCP 連携の唯一のセキュリティ境界**（セキュリティ不変条件）。admin の NOPASSWD sudo は生きているため、ここを抜かれると全部抜ける。`$SSH_ORIGINAL_COMMAND` を**シェルに渡さない**（`eval` / `sh -c` を使わない）。`read -ra` で配列へ分解し `case` で完全一致判定してから、スクリプト内に固定で書いた引数配列で `sudo` を exec する。引数は型（整数・IP アドレス書式）で検証し、許可されないものは**エラー内容を返さず終了コードのみ**。許可リストは読み取り 6 コマンドのみで、書き込み系（削除・失効・設定変更）を足さない。`authorized_keys` 側の `command=` と `restrict` を付け忘れると全権の鍵になるため、`make doctor` がこれを検査する。
- **`NAME` 引数のインジェクション対策**: Makefile は `NAME` をレシピ文字列に展開せず `export NAME` で環境変数として渡し、`NAMECHECK`（英数・ハイフン・アンダースコアのみ）で検証してから `$$NAME` を参照する。クライアント名を扱う新ターゲットでも必ず `@$(NAMECHECK)` を冒頭に置き、同じ方式を守る。
- OS は cloud-init + apt 前提のため **Debian / Ubuntu 系のみ**（RHEL 系不可）。512MB プランでは `setup.sh` が apt のメモリ不足を防ぐため swap を確保する。

## ローカル設定

`orenovpn.local.mk`（gitignore 済み）に `SSH_KEY = ~/.ssh/orenovpn` などを書くと毎回の指定を省ける。Makefile が `-include` する。SSH 接続情報（`SSH_HOST` / `SSH_USER`）は `terraform output` から遅延展開で取得するため、`make deploy` 完了後にのみ有効。

## 詳しいドキュメント

`docs/` に `SETUP.md`（詳細手順）・`USAGE.md`（クライアント/接続）・`SECURITY.md`・`TROUBLESHOOTING.md`・`ALERTING.md`（通信監視・警告機能の設計と運用）・`RETROSPECTIVE.md`（設計判断と既知問題の経緯）。設計の「なぜ」を追うときは RETROSPECTIVE を見る。
