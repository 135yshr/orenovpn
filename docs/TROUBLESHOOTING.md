# 構築ログ / トラブルシューティング記録

ConoHa VPS Ver.3.0 上に本テンプレートで VPN を実際に構築する過程で遭遇した問題と、
その原因・対処・結果を時系列で記録したもの。ConoHa 固有の落とし穴が多く、同じ轍を
踏まないための知見として残す。

> 凡例: **症状** → **原因** → **対処** → **結果**（該当コミット）

---

## 1. ボリュームタイプが存在しない

- **症状**: `terraform apply` で `specified volume type does not exist`（400）。
- **原因**: `volume_type` の既定値 `c3j1-ds02` が実在しなかった。ConoHa v3 のブート用
  ボリュームタイプは末尾が `-boot`（例 `c3j1-ds02-boot`）。
- **対処**: 既定を `c3j1-ds02-boot` に修正。確認用に `make volume-types`
  （`scripts/list-volume-types.sh`）を追加。
- **結果**: 解決。（`86a36cf`）

## 2. ブートボリュームのサイズがプランと不整合

- **症状**: サーバー作成時に `512MB plan can only attach 30GB boot volume`（400）。
- **原因**: `volume_size` 既定 100GB が 512MB プランと不整合。512MB プランは 30GB 固定。
- **対処**: 既定を 30 に変更。プランとサイズの対応をコメントに明記。
- **結果**: 解決。（`2a8c531`）

## 3. user_data が 16KiB 制限を超過

- **症状**: `User data size must be under 16KiB`。当初スクリプトを base64 埋め込みして
  いたため約 19KiB になっていた。
- **試行錯誤**:
  - gzip 圧縮（`base64gzip`）→ ConoHa が `User data header is invalid` を返し**gzip 不可**と判明。
  - プレーンテキスト埋め込み → プロバイダが送信時に base64 化するため実質 +33% となり
    なお超過（制限は**base64 後**のサイズに適用）。
  - スクリプトのコメント/空行を最小化 → 一旦 15KB 台に収めた。
- **最終対処**: **構築を 2 フェーズ化**（下記 4）してスクリプトを user_data から排除。
  user_data は約 1.9KiB に激減し問題自体を根絶。
- **結果**: 解決。（`a193a9e` → `33cc45a` → `4c8f604` → 最終的に `8719127` で解消）

## 4. 「起動したのに SSH で入れない」／デバッグ性の悪さ

- **症状**: 初回ブートで全部やる方式だと、失敗時に SSH すら入れず原因が見えない。
- **対処**: **2 フェーズ構成に再設計**。
  - フェーズ1（cloud-init・最小限）: ユーザー作成 + SSH 鍵 + SSH 堅牢化のみ。
  - フェーズ2（`make setup`）: スクリプトを SSH 転送し、パッケージ導入・VPN 構成を
    画面で見ながら実行（冪等・再実行可能）。
- **結果**: デバッグ性が大幅改善。user_data も最小化（上記 3 も同時に解消）。（`8719127`）

## 5. SSH ポート変更が反映されない（当初の誤診）

- **症状**: `ssh_port` を 22 以外にすると全く接続できない。
- **当初の推測**: Debian 13 の SSH ソケットアクティベーション（`ssh.socket`）で
  `sshd_config` の `Port` が無視される、と考え socket 無効化を実装（`378a355`）。
- **真因**: 実は下記 6（user_data 未適用）が原因で、sshd_config ドロップイン自体が
  書かれておらず 22 番のままだった。socket 説は的外れだった。
- **最終対処**: ポート変更機能は「利点が少なく事故要因」として**廃止し SSH は 22 番固定**に。
  防御は鍵認証＋fail2ban が担う。
- **結果**: 解決（機能削除）。（`47abee4`）

## 6. ★最重要: user_data が cloud-init に適用されない（config_drive 欠如）

- **症状**: SSH で root＋鍵では入れるが、`vpnops` ユーザーが作られず、SSH 堅牢化も
  未適用。`cloud-init status` は `done` なのに `#cloud-config` の中身が反映されない。
- **原因**: **ConoHa は metadata サービス経由の user_data を cloud-init に渡さない**。
  鍵は metadata 経由で root に注入されるが、user_data(#cloud-config) は
  **config-drive 経由でないと処理されない**。
- **対処**: インスタンスに **`config_drive = true`** を追加。あわせて cloud-init を
  ロックアウト耐性に（root 鍵ログインを残す・swap を setup.sh 側へ移動）。
- **結果**: **解決（最大の突破口）**。`make status` が `SSH 疎通OK` になり vpnops で
  ログイン可能に。これ以前の SSH 不通の多くはこれが真因だった。（`8616631`）

## 7. SSH 秘密鍵のパスが既定外

- **症状**: `make status` が `Permission denied (publickey)`。
- **原因**: 鍵が `~/.ssh/orenovpn`（既定 `~/.ssh/id_ed25519` ではない）。
- **対処**: `SSH_KEY=` で指定可能に。さらに `orenovpn.local.mk`（gitignore）や環境変数
  `ORENOVPN_SSH_KEY` で毎回指定を省略できるようにした。
- **結果**: 解決。（`5aa3e86`）

## 8. allowed_ssh_cidr がプレースホルダのまま

- **症状**: SSH ルールが `203.0.113.10/32`（ドキュメント例のIP）で作られ、実 IP から
  SSH 不可。
- **原因**: hardened 系設定の `allowed_ssh_cidr` プレースホルダを実 IP に置換していなかった。
- **対処**: 自分のグローバル IP（`curl -4 ifconfig.co`）または `0.0.0.0/0` に設定。
- **結果**: 解決（設定修正）。

## 9. iPhone への構成ファイル配布

- **背景**: IKEv2 の `.mobileconfig` はサーバー上に root 所有(0600)で生成され、iPhone
  から直接は取得できない。
- **対応**:
  - `make profile`: SSH(22) 経由で Mac にダウンロード（`sudo cat`）→ AirDrop/メール等で転送。（`5c9d7e2`）
  - `make serve-profile`: VPS から一時 HTTPS + QR 配信（iPhone の Safari で直接取得）。

## 10. serve-profile: 動的に追加した SG ルールが効かない

- **症状**: 一時ポートを API で SG に追加しても、Mac からも到達不可（timeout）。
  サーバー内では待受 OK・ufw OK・localhost 200。
- **原因**: **ConoHa は稼働中インスタンスに「後から追加した SG ルール」を反映しない**。
  SG オブジェクトには存在するが、実インスタンスのフィルタに適用されない。
- **対処**: 配信ポートを **Terraform で作成時から SG に宣言**する方式へ変更
  （`enable_profile_download` / `profile_port`）。serve-profile は SG を触らず
  ufw 開閉＋配信のみ（ufw は即反映される）。（`0e119f6`）
- **結果**: 部分的。下記 11・12 へ続く。

## 11. serve-profile の権限バグ

- **症状**: クライアントが「見つからない」／`serve.py` を書けない。
- **原因**: クライアントファイルは `/etc/orenovpn/clients`(0700/root) にあり、vpnops の
  `[ -f ]` では検出不可。配信 dir を `sudo mkdir` すると vpnops が書き込めない。
- **対処**: `sudo test -f` に変更、配信 dir は非 sudo で作成。（`5f77711`）
- **結果**: 解決。

## 12. 作成時に宣言した 443 すら外部から到達不可（解決・真因は nftables）

- **症状**: 443 を作成時から SG に宣言し、depends_on で全ルールをインスタンス前に
  作成しても、443 だけ外部から timeout（22/500/4500 は到達可）。
  サーバー内は待受 OK・ufw ALLOW・localhost 200。SG オブジェクトにも 443 は存在。
- **切り分けで判明**:
  - サーバー/ufw/証明書は正常（localhost=200）。遮断は ConoHa ネットワーク層。
  - `depends_on`（ルールをインスタンス前に作成）でも改善せず → 作成時タイミングの
    問題ではない。
  - ConoHa には `IPv4v6-Web`(80/443) 等の**定義済み SG** が存在。
- **現在の仮説**: **ConoHa は 80/443（Web 標準ポート）を特別扱いし、カスタム SG ルール
  では開かない**（22 はカスタムルールで開くのに 443 は開かない、と整合）。
- **対処（検証1）**: 配信ポートを **8443**（カスタム高位ポート）に変更。（`ac7e717`）
- **検証1の結果**: **8443 も外部到達不可**（待受・ufw・localhost は正常）。
  → 443 特有ではなく、**ConoHa は 22 以外のカスタム SG TCP ルールを実質適用していない**
  可能性が濃厚。22/500/4500 のみ通り、それ以外の TCP は塞がれる。
- **対処（検証2）**: ConoHa の**定義済み SG `IPv4v6-Web`（80/443 を開く）**をインスタンスに
  アタッチし、配信ポートを 443 に戻す方式へ。定義済み SG なら ConoHa が確実に適用する想定。
- **結果**: `IPv4v6-Web` アタッチで 443 配信は解決。（`7a247c3`）
- **⚠️ 後日判明した真因**: 「ConoHa は 22 以外のカスタム TCP ルールを適用しない」という
  当時の仮説は**誤り**だった。実際の遮断要因は Debian 13 既定の **nftables `table inet filter`**
  （input policy drop・22 のみ許可）で、これが 443/8443 を含む全ポートを弾いていた（下記 13）。
  nftables を無効化した後は**カスタム TCP SG ルールも正常に機能する**ことを、ランダム配信
  ポート（20000〜60000 のカスタムルール）で外部到達できたことで確認済み（下記 15）。

## 13. 真の遮断要因は Debian 13 既定の nftables だった

- **症状**: 22/500/4500 以外（443/8443/配信ポート）が外部から一切到達しない。SG・ufw・
  待受・localhost はすべて正常。長く「ConoHa がカスタム TCP を適用しない」と誤認していた。
- **原因**: Debian 13 は既定で **`nftables.service` が `/etc/nftables.conf` を読み込み、
  `table inet filter`（input policy drop・SSH 22 のみ許可）** を適用する。これが ufw とは別に
  常駐し、22 以外の全ポートを破棄していた。ufw だけ見ていて見落としていた。
- **切り分け**: 「ufw 以外にパケットを破棄するものは？実プロセスを確認したか？」の指摘で
  `nft list ruleset` を確認 → `table inet filter` を発見。
- **対処**: setup.sh で `systemctl disable --now nftables` ＋ 実行中の `table inet filter` を
  削除し、ファイアウォールを **ufw に一本化**。
- **結果**: 解決。以後は 443・カスタム高位ポートとも到達可能に。（`17712c2`）
- **教訓**: 同種機能（ufw と nftables）の二重起動を最初に確認すべき。`nft list ruleset` /
  `systemctl list-units '*fire*' '*nft*'` を初手の点検に入れる。

## 14. QR 配布時に自己署名証明書の警告で止まる

- **症状**: `make serve-profile` の QR を iPhone Safari で開くと「この接続は
  プライバシーが保護されません」の警告が出て、先に進めず構成プロファイルを取得できない。
- **原因**: 一時 HTTPS 配信に自己署名証明書を使っていたため。
- **対処**: 配信ホスト名を **`<IP>.sslip.io`**（IP に解決される公開ワイルドカード DNS）にし、
  **Let's Encrypt（HTTP-01・ポート80）で信頼された証明書**を取得して配信。取得済み証明書は
  サーバーにキャッシュして再利用（LE レート制限回避）。取得失敗時は自己署名にフォールバック。
  独自ドメインがあれば `PROFILE_DOMAIN` で指定可能。ポート 80 は `IPv4v6-Web` が担保。
- **結果**: 解決。警告なしでプロファイルを取得できるように。（`f36bd88`）

## 15. 配信ポートのランダム化（カスタム TCP SG ルールの機能確認）

- **背景**: 既知ポート(443)を避けたいという要望。ConoHa は SG を作成時にしか反映しないため
  「毎回ランダム」は不可だが、「デプロイ単位でランダム固定」なら可能。
- **対処**: `randomize_profile_port=true` で `random_integer`(20000〜60000) を apply 時に決定し、
  そのポートの**カスタム SG ルール**(`profile_v4/v6`, TCP) を作成。`profile_port` 出力を
  serve-profile が自動使用。80 は LE 用に `IPv4v6-Web` で確保。
- **結果**: ランダム TCP ポートで外部から配信到達を確認。これにより **nftables 無効化後は
  カスタム TCP SG ルールが正常に機能する**ことが実証された（12 の仮説の反証）。（`f36bd88`）

## 16. IKEv2 接続が ON にした直後 OFF に戻る（AUTH_FAILED）

- **症状**: プロファイル導入後、VPN を ON にすると即 OFF。サーバーログに
  `received end entity cert "CN=iphone"` → `no trusted RSA public key found for 'iphone'`
  → `N(AUTH_FAILED)`。
- **切り分け**: 証明書チェーンは正常（`openssl verify` OK、CA-SKI と client-AKI 一致、
  CA は swanctl に CA フラグでロード済み）。つまり中身ではなく**識別子(ID)の型**の問題。
- **原因**: クライアント証明書の SAN が **`email:iphone`(rfc822Name)** のみ。一方 iOS は
  mobileconfig の `LocalIdentifier="iphone"`（＠なし）を **`ID_FQDN` 型**で送る。strongSwan は
  ID_FQDN に一致する **dNSName** SAN を探すが無いため「該当する信頼鍵なし」となっていた。
- **対処**: クライアント証明書の SAN に **`DNS:<name>` を追加**（email も残し両対応）。
- **結果**: 解決。`authentication ... successful` → `IKE_SA established` / `CHILD_SA established`。
  （`3b8628b`）

## 17. VPN は張れるがインターネットが使えない（戻り通信ゼロ）

- **症状**: トンネル確立後、`swanctl --list-sas` が `in` は増えるが **`out 0 packets`**。
  端末からサイトが開けない。
- **原因**: `setup_ikev2` が `/etc/ufw/before.rules` に追記した NAT(MASQUERADE) を、
  直後の **`ufw --force reset` がデフォルトへ戻して消していた**。SNAT されないため
  戻りパケットが VPN 内部 IP 宛のまま返らず疎通不可。
- **対処**: NAT 適用を `apply_ikev2_nat()` に分離し、**ufw リセット後・enable 前**に呼ぶ順序へ。
  さらに enable 後の冗長な `ufw reload`（同一ルール二重登録の原因）を削除。
- **結果**: 解決。`out` にトラフィックが流れ双方向疎通。（`fa6c1bc` / `4855c8f`）

## 18. IPv6 リークと v6 プール未割当

- **症状**: IKEv2 接続時にログへ `no virtual IP found for %any6 requested by 'iphone'`。
  v6 内部アドレスが配布されず、端末のネイティブ v6 がトンネル外へ漏れうる状態。
- **原因**: swanctl の `pool.addrs` に **v4/v6 を混在指定**していたため、v6 レンジが
  読み込まれていなかった（1 プール 1 アドレス族が確実）。
- **対処**: v4/v6 を**別プール**(`orenovpn_pool` / `orenovpn_pool6`)に分離し、connection の
  `pools` に両方を指定。あわせて経路強化として v6 のみ `::/0` を提示・NAT66 を before6.rules に
  追加（v6 出口が無ければ破棄＝トンネル外へ漏れない）、鍵ローテーション(IKE 4h/CHILD 1h)＋
  ESP に DH 群を含め PFS も有効化。
- **結果**: 解決。`remote 'iphone' ... [10.66.66.1 fd42:66:66::1]` と v6 も割当。
  （`3437772` / `fa6c1bc`）

## 19. ★不正アクセス調査で判明した「認証なしで入れる」経路

「知らない接続があった」という報告を起点にコードを点検して見つかったもの。いずれも
**VPN の暗号やハンドシェイクを破るものではなく、資格情報の配布と転送許可の設計不備**。

- **症状**: 想定外のアクセス。`wg show` の peer 一覧は増えず、監視の「新規 VPN 接続」も
  鳴らないため、事後にしか気づけない。
- **原因1（配信）**: `serve-profile.sh` が `SimpleHTTPRequestHandler` を使っていたため、
  index の無いディレクトリに **autoindex（ファイル一覧）** が返り、防御の中心だった
  「推測不能な URL トークン」がそのまま列挙されていた。配信ディレクトリには
  `.mobileconfig`（p12 の復号パスワードを平文で含む）を `chmod 644` で複製し、
  Let's Encrypt の秘密鍵も同じ場所に置いていた。配信ポートは既定 443 で SG は常時許可、
  さらに証明書取得によりホスト名が Certificate Transparency に即時公開されるため、
  スキャナに「今ここで配信中」と知らせているのと同じ状態だった。
- **原因2（後片付け）**: ufw を閉じる処理が手元スクリプトの `trap` だけに依存しており、
  回線切断や SIGKILL では発火せず、穴と平文の配布物が残り得た。
- **原因3（転送）**: WireGuard の PostUp が `-o wg0 -j ACCEPT` を FORWARD の先頭に置き、
  MASQUERADE に `-s` が無かったため、外部から「宛先=VPN サブネット」のパケットが
  **VPN 認証なしにトンネルへ転送され、戻りも NAT されて成立**していた。IKEv2 側は
  `DEFAULT_FORWARD_POLICY="ACCEPT"` で全転送を許可＝オープンルーター状態。
- **原因4（失効）**: `enable_cert_revocation` の既定が false で、`make remove` は
  ファイル削除のみ。漏れた `.mobileconfig` を**10 年間止められない**。さらに remove が
  証明書の原本を削除するため、後から失効に切り替えても失効できなくなっていた。
- **対処**:
  - 配信を専用ハンドラ（`BaseHTTPRequestHandler`）に置き換え、トークン完全一致・
    Host 一致・ダウンロード回数上限・時間上限・`/var/log/orenovpn-serve.log` への
    全要求記録に。配布物は複製せず root 専有パスから直接読む。証明書類は 0600。
  - サーバー側 watchdog（`setsid` で分離）が時間経過後に必ず ufw を閉じ、作業ディレクトリを
    消す。待受を上げてから ufw を開ける順序に変更（露出時間の最小化）。
  - 転送は向きとサブネットで限定し、`DEFAULT_FORWARD_POLICY=DROP` を維持。IKEv2 は
    `-m policy --pol ipsec` で「IPsec を通ってきたか」を確認（xt_policy が無い環境は
    サブネット限定にフォールバックし `make doctor` が警告）。既存インスタンスは
    `make setup` の再実行で旧ルールを撤去して移行する。
  - `enable_cert_revocation` の既定を **true** に。失効できない場合は証明書の原本を
    残し、理由と復旧手順を表示する。
  - 監視に「資格情報の複製」検知（同一の鍵/証明書 ID が 1 時間に複数 IP から）を追加。
  - `make doctor` に転送ポリシー・MASQUERADE のスコープ・配信ポートの開放残り・
    CRL 無効の点検を追加。
- **学び**: VPN の実質的な攻撃面は**暗号ではなく資格情報の配布経路と転送許可**。
  「トークンで守っている」と書いてあっても、ライブラリの既定挙動（autoindex）が
  それを無効化していないかまで確認する。後片付けは操作端末側の trap に依存させず、
  サーバー側で必ず閉じる仕組みを持たせる。

---

## ConoHa 固有の落とし穴（まとめ）

1. **ブートボリューム**: タイプは `-boot` 付き、サイズはプラン固定（512MB→30GB）。
2. **user_data は config-drive が必須**（`config_drive = true`）。metadata 経由では
   cloud-init に適用されない。← 最重要。
3. **user_data 16KiB 制限は base64 後のサイズ**に適用。gzip user-data は不可。
4. **SG ルールは稼働中インスタンスに後から反映されない**。必要なポートは
   インスタンス作成時までに SG へ宣言しておくこと。
5. **カスタム SG の TCP ルールは正常に機能する**（当初「22 以外の TCP は不可」と誤認したが
   真因は下記 6 の nftables。無効化後は任意 TCP ポートが到達可能）。LE 用の 80 は定義済み
   `IPv4v6-Web` を併用すると確実。
6. **Debian 13 は既定で nftables が常駐**し 22 以外を破棄する。ufw と二重になるため
   `systemctl disable --now nftables` で ufw に一本化する（最重要級の落とし穴）。
7. SSH のポート変更は避け 22 番固定が無難（socket activation 等の事故要因）。

## 20. 出口通信の LOG が WireGuard では一度も発火しない（アクセス先記録の設計理由）

- **症状**: `alert_blocklist_url` を設定しても、WireGuard 構成では悪性 IP への通信が
  検知されない（IKEv2 では検知される）。
- **原因**: LOG ルールを ufw の `ufw-before-forward` 鎖に入れているが、WireGuard の
  転送許可は `wg0.conf` の PostUp が **FORWARD の先頭**（ufw のチェーンへの jump より前）に
  入れて ACCEPT してしまうため、パケットが ufw のチェーンに到達しない。
- **対処**: アクセス先の記録（`enable_access_log` / `enable_dns_logging`）は
  **`nat PREROUTING`** にルールを置く。PREROUTING は FORWARD より前に通り、かつ新規接続の
  最初のパケットだけが通るため「1 接続 1 行」で両プロトコルともに記録できる。
  適用は `orenovpn-fwlog.service`（`iptables -C` してから `-A` する冪等スクリプト）が担う
  （`before.rules` に書くと `ufw reload` が noflush で再適用して二重登録になる）。
- **学び**: 「ルールを書いた」＝「そこを通る」ではない。**パケットが実際にそのチェーンに
  到達するか**を、鎖の順序まで含めて確認する（`iptables -S FORWARD` の先頭を見る）。

## 21. `make doctor` が「53 番の待受が無い」と誤検知する（ss の列位置）

- **症状**: unbound は正常に稼働・待受しているのに `[WARN] 53 番の待受が無い` が出る。
  さらに `orenovpn-fwlog-apply` がこの判定を使うと、待受があるのに DNS の DNAT を
  入れなくなり、名前解決の記録が静かに止まる。
- **原因**: `ss` は**指定するプロトコルによって `Netid` 列の有無が変わる**。
  - `ss -tuln` … `Netid State Recv-Q Send-Q Local:Port Peer:Port` → ローカルは **$5**
  - `ss -uln` … `State Recv-Q Send-Q Local:Port Peer:Port`（Netid 列なし）→ ローカルは **$4**

  `ss -uln` に対して `$5` を見ていたため、常に Peer 側（`0.0.0.0:*`）を読んでいた。
  「待受なし」と誤判定するだけでなく、**`0.0.0.0:53`（オープンリゾルバ）の検出も
  効かない**という危険な偽陰性になっていた。
- **対処**: 列位置に依存せず、**全フィールドから `:53` で終わる字句を拾う**。

  ```bash
  ss -uln | awk 'NR > 1 {for (i = 1; i <= NF; i++) if ($i ~ /:53$/) print $i}'
  ```

- **学び**: `ss` / `netstat` の出力を列番号で拾うのは、オプションの組み合わせで壊れる。
  ポート番号や `:53$` のようなパターンで拾うか、`grep` で行単位に判定する
  （このリポジトリの他の待受チェックが `grep -q ":${p} "` で正しく動いていたのはこのため）。

## 22. IKEv2 が接続できるのにインターネットに出られない（プールとサーバーアドレスの衝突）

- **症状**: VPN の接続自体は成功する（`swanctl --list-sas` に ESTABLISHED が出る）のに、
  端末から Web が開かない・名前解決もできない。`make doctor` は転送も NAT も OK と出る。
- **原因**: `pools.orenovpn_pool.addrs` に VPN サブネットをそのまま指定していたため、
  strongSwan が**先頭アドレス（`10.66.66.1`）から払い出す**。これは DNS 記録機能が
  自前リゾルバ用に `lo` へ付与しているサーバー自身のアドレスと同じで、次の二重障害になる。
  - クライアント自身の住所 = 配布された DNS サーバーのアドレス → 名前解決が自分に向いて失敗
  - 戻り通信の宛先がサーバーのローカルアドレスになり、トンネルへ転送されず**サーバーに吸われる**
- **対処**: プールをサーバーアドレスを除いた範囲にする（swanctl の `addrs` は範囲指定に対応）。

  ```
  pools {
    orenovpn_pool  { addrs = 10.66.66.2-10.66.66.254 }
    orenovpn_pool6 { addrs = fd42:66:66::2-fd42:66:66::ffff }
  }
  ```

  反映は `sudo /usr/local/sbin/setup.sh`（または `make setup`）→ 端末を再接続。
  `make doctor` がプール先頭とサーバーアドレスの一致、および実際のリースの衝突を検出する。
- **学び**: WireGuard では `wg0` が `.1` を持ちクライアントは `.2` からなので衝突しないが、
  IKEv2 はプールがサブネット全体だと `.1` から配る。**「サーバーが持つアドレス」と
  「クライアントへ配るアドレス」の範囲が重ならないことを設計時に確認する**。
  転送・NAT・ファイアウォールがすべて正常でも、アドレス設計だけで通信不能になる。

## セキュリティ上の不変条件（壊すと「認証なしで入れる」状態に戻る）

1. **配信サーバーに `SimpleHTTPRequestHandler` を使わない**。autoindex で URL トークンが
   列挙され、配布物（＝資格情報）が誰でも取得できる。
2. **`DEFAULT_FORWARD_POLICY` は `DROP`**。`ACCEPT` にすると VPN と無関係な通信まで
   中継する（踏み台/リフレクタ化）。
3. **MASQUERADE には必ず `-s <VPN サブネット>`**、FORWARD の許可は向きまで限定する。
   `-o wg0 -j ACCEPT` のような無条件許可は外部からトンネル内への到達を許す。
4. **IKEv2 の失効(CRL)は有効のまま**。無効だと漏洩した証明書を止められない。
5. **DNS 記録の unbound は VPN 内アドレスと localhost だけに待受させる**。全アドレスや
   グローバル IP で待受するとオープンリゾルバ（増幅攻撃の踏み台）になる。
6. 上記はすべて `make doctor` が点検する。構成を触ったら `make doctor` を実行する。

## VPN（IKEv2/IPsec）構成の要点

- クライアント証明書の SAN は iOS が送る ID 型に合わせる（`LocalIdentifier` が素の文字列なら
  **dNSName** を含める）。SAN 型不一致は `no trusted public key found` → AUTH_FAILED になる。
- NAT(MASQUERADE) を ufw の before.rules で入れる場合、**`ufw --force reset` の後**に適用する
  （リセットで消える）。戻り通信ゼロ＝NAT 未適用を最初に疑う。
- swanctl のアドレスプールは **v4/v6 を別プール**に分ける。混在指定は v6 が読まれない。

## 検証手段として整備したもの

- `make images` / `make volume-types`: 利用可能な OS イメージ・ボリュームタイプの確認。
- 2 フェーズ構成 + `make setup` の画面出力: 構成失敗をその場で観察・再実行。
- `serve-profile` の `[diag]` 出力 + Mac からの到達性自己テスト: 障害が
  サーバー/ufw/SG のどの層かを切り分け。
