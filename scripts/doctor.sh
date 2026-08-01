#!/usr/bin/env bash
#
# doctor.sh : orenovpn サーバーの構成を自己診断する（`make doctor` が SSH 経由で実行）。
#   「VPN に繋がらない/通信できない」ときの原因切り分けを一撃で行うためのもの。
#   過去に長時間ハマった箇所（nftableの二重稼働・NAT未適用・LISTEN・IP転送・v6プール）を
#   自動点検する。サーバー上で（sudo 可能なユーザーで）実行される想定。
#
set -u
S=sudo
ENVF=/etc/orenovpn/orenovpn.env

getenv() { $S grep -E "^$1=" "$ENVF" 2>/dev/null | head -1 | sed -E 's/^[^=]*="?([^"]*)"?.*/\1/'; }

PROTO="$(getenv VPN_PROTOCOL)"; PROTO="${PROTO:-wireguard}"
WGPORT="$(getenv WG_PORT)"
V6="$(getenv WG_ENABLE_IPV6)"
CRL="$(getenv ENABLE_CERT_REVOCATION)"
SUB4="$(getenv WG_SUBNET_V4)"
# サーバー自身の VPN 内アドレス。プロトコル別のブロック（IKEv2 のプール衝突検査）と
# プロトコル共通のブロック（DNS 待受の許可リスト）の両方で使うため、ここで必ず定義する。
# 片方のブロックだけで代入すると set -u により WireGuard 構成で doctor が途中終了する。
SRVADDR="$(getenv WG_ADDRESS_V4)"
SRV6="$(getenv WG_ADDRESS_V6)"

ok=0; warn=0; fail=0
pass() { echo "[ OK ] $*"; ok=$((ok + 1)); }
wrn()  { echo "[WARN] $*"; warn=$((warn + 1)); }
bad()  { echo "[FAIL] $*"; fail=$((fail + 1)); }

echo "== orenovpn doctor (protocol=${PROTO}) =="

# 1. ファイアウォールの二重稼働（過去最大の落とし穴）
if $S systemctl is-active --quiet nftables 2>/dev/null; then
  bad "nftables.service が稼働中（ufw と二重。22以外を遮断しうる）→ sudo systemctl disable --now nftables"
elif $S nft list ruleset 2>/dev/null | grep -q 'table inet filter'; then
  wrn "nftables は停止だが 'table inet filter' がロード中 → sudo nft delete table inet filter"
else
  pass "nftables による二重遮断なし"
fi
if $S ufw status 2>/dev/null | grep -q "Status: active"; then pass "ufw 稼働中"; else wrn "ufw が非稼働"; fi

# 1.5 転送の限定（踏み台化・外部から VPN 内への侵入の点検）
# DROP 以外（ACCEPT・未設定・想定外の値）はすべて FAIL にする。
# 未設定を "DROP" と表示して通すと、実際の値が分からないまま安全だと誤認する。
FWD="$($S grep -E '^DEFAULT_FORWARD_POLICY=' /etc/default/ufw 2>/dev/null | cut -d'"' -f2)"
if [ "$FWD" = "DROP" ]; then
  pass "転送既定は DROP（VPN 用の転送のみ明示許可）"
elif [ "$FWD" = "ACCEPT" ]; then
  bad "ufw の転送既定が ACCEPT（VPN 以外の通信まで中継＝踏み台/リフレクタ化）→ sudo /usr/local/sbin/setup.sh"
else
  bad "ufw の転送既定が DROP ではない（値: ${FWD:-未設定}）→ sudo /usr/local/sbin/setup.sh"
fi
if $S iptables -t nat -S POSTROUTING 2>/dev/null | grep -q -- '-j MASQUERADE'; then
  if $S iptables -t nat -S POSTROUTING 2>/dev/null | grep -- '-j MASQUERADE' | grep -qv -- '-s '; then
    wrn "送信元指定の無い MASQUERADE がある（VPN 以外の転送も NAT される）→ sudo /usr/local/sbin/setup.sh"
  else
    pass "MASQUERADE は VPN サブネット限定"
  fi
fi

# 1.7 構成ファイル配信（make serve-profile）の後片付け点検
#     配布物は VPN 資格情報そのもの。開いたままのポートや残存ファイルは即リスク。
if $S test -d /run/orenovpn-serve || $S test -d /tmp/orenovpn-serve; then
  wrn "配信用の一時ディレクトリが残存（クライアント設定が置かれた可能性）→ sudo rm -rf /run/orenovpn-serve /tmp/orenovpn-serve"
fi
if ! $S pgrep -f 'orenovpn-serve/serve.py' >/dev/null 2>&1; then
  STRAY="$($S ufw status 2>/dev/null | awk '$1 ~ /\/tcp$/ && $1 !~ /^22\// {print $1}' | sort -u | tr '\n' ' ')"
  if [ -n "$STRAY" ]; then
    wrn "配信していないのに TCP 許可が残っている: ${STRAY}→ sudo ufw delete allow <port>/tcp"
  else
    pass "配信ポートは閉じている（SSH 以外の TCP 許可なし）"
  fi
fi

# 2. IP 転送（VPN 中継に必須）
if [ "$($S sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ]; then pass "IPv4 転送 有効"; else bad "IPv4 転送が無効（中継不可）"; fi
if [ "$V6" = "true" ]; then
  if [ "$($S sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)" = "1" ]; then pass "IPv6 転送 有効"; else wrn "IPv6 転送が無効"; fi
fi

# 3. NAT（戻り通信に必須。過去に ufw reset で消えた）
if $S iptables -t nat -S POSTROUTING 2>/dev/null | grep -qi masquerade; then
  pass "NAT(MASQUERADE) 設定あり"
else
  bad "NAT(MASQUERADE) が無い（戻り通信ゼロ＝内部が使えない）"
fi

# 4. プロトコル別: サービス稼働 / 待受ポート / v6プール / CRL
if [ "$PROTO" = "ikev2" ]; then
  if $S systemctl is-active --quiet strongswan 2>/dev/null || $S systemctl is-active --quiet strongswan-swanctl 2>/dev/null; then
    pass "strongSwan 稼働中"
  else
    bad "strongSwan が非稼働 → journalctl -u strongswan"
  fi
  for p in 500 4500; do
    if $S ss -uln 2>/dev/null | grep -q ":${p} "; then pass "UDP ${p} LISTEN"; else bad "UDP ${p} が LISTEN していない"; fi
  done
  if [ "$V6" = "true" ]; then
    if $S swanctl --list-pools 2>/dev/null | grep -q orenovpn_pool6; then pass "IPv6 プール(orenovpn_pool6) あり"; else wrn "IPv6 プールが無い（v6 リークの恐れ）"; fi
  fi
  # プールがサーバー自身のアドレスを払い出すと、クライアントの住所と配布DNSが同じになり
  # 名前解決できず、戻り通信もサーバーに吸われて「VPN は張れるが通信できない」状態になる。
  if [ -n "$SRVADDR" ] && $S swanctl --list-pools 2>/dev/null | grep -qF "${SRVADDR}-"; then
    bad "アドレスプールの先頭がサーバー自身の ${SRVADDR}（クライアントと衝突し通信不可）→ sudo /usr/local/sbin/setup.sh"
  elif [ -n "$SUB4" ] && $S grep -qF "addrs = ${SUB4}" /etc/swanctl/swanctl.conf 2>/dev/null; then
    bad "アドレスプールがサブネット全体（${SUB4}）で先頭がサーバー自身と衝突する → sudo /usr/local/sbin/setup.sh"
  else
    pass "アドレスプールはサーバー自身のアドレスを含まない"
  fi
  # 実際に払い出された住所がサーバーのものと一致していないか（衝突時の直接検出）
  if [ -n "$SRVADDR" ] && $S swanctl --list-sas 2>/dev/null | grep -qF "${SRVADDR}]"; then
    bad "クライアントにサーバー自身の ${SRVADDR} が割り当てられている（要 setup.sh 再実行と再接続）"
  fi
  if [ "$CRL" = "false" ]; then
    bad "証明書失効(CRL)が無効: プロファイル漏洩・端末紛失時に接続を止められない（証明書は10年有効）→ enable_cert_revocation=true にして make setup"
  elif $S test -f /etc/swanctl/x509crl/orenovpn.crl; then
    pass "CRL 配置あり（失効チェック有効）"
  else
    wrn "CRL 未配置（make setup を再実行して生成してください）"
  fi
  # 外部から VPN サブネットへ入れる転送許可になっていないか。
  # xt_comment が使えない環境では目印が付かないため、VPN サブネット指定でも判定する。
  FWDRULES="$($S iptables -S ufw-before-forward 2>/dev/null)"
  if printf '%s\n' "$FWDRULES" | grep -q 'orenovpn-vpn-forward' \
     || { [ -n "$SUB4" ] && printf '%s\n' "$FWDRULES" | grep -qF -- "-s ${SUB4}"; }; then
    if printf '%s\n' "$FWDRULES" | grep -q -- '--pol ipsec'; then
      pass "IPsec 転送許可は policy 一致で限定（平文の外部パケットは転送しない）"
    else
      wrn "IPsec 転送許可が policy 一致なし（xt_policy 不在時の代替）。送信元偽装の余地が残る"
    fi
  else
    bad "IPsec 用の転送許可ルールが無い（通信不可、または全開放）→ sudo /usr/local/sbin/setup.sh"
  fi
  active_sas="$($S swanctl --list-sas 2>/dev/null | grep -c ESTABLISHED)"
  echo "[INFO] 確立中の IKE_SA: ${active_sas:-0}"
elif [ "$PROTO" = "wireguard" ]; then
  if $S wg show 2>/dev/null | grep -q interface; then pass "WireGuard(wg0) 稼働中"; else bad "WireGuard が非稼働 → systemctl status wg-quick@wg0"; fi
  if [ -n "$WGPORT" ] && $S ss -uln 2>/dev/null | grep -q ":${WGPORT} "; then pass "UDP ${WGPORT} LISTEN"; else bad "UDP ${WGPORT:-?} が LISTEN していない"; fi
  # 外部から VPN 内へ到達できる緩い転送ルールが残っていないか
  if $S iptables -S FORWARD 2>/dev/null | grep -qE '^-A FORWARD -o wg0 -j ACCEPT$'; then
    bad "FORWARD に '-o wg0 -j ACCEPT' が残存（外部から VPN 内の端末へ到達可能）→ sudo /usr/local/sbin/setup.sh"
  else
    pass "外部から VPN 内へ入れる転送ルールなし"
  fi
  peers="$($S wg show 2>/dev/null | grep -c peer)"
  echo "[INFO] 登録ピア数: ${peers:-0}"
fi

# 5. 通信監視・警告（ENABLE_TRAFFIC_ALERT=true のときのみ点検）
ALERT="$(getenv ENABLE_TRAFFIC_ALERT)"
if [ "$ALERT" = "true" ]; then
  if $S systemctl is-active --quiet orenovpn-watch.timer 2>/dev/null; then pass "監視 timer(orenovpn-watch) 稼働中"; else bad "orenovpn-watch.timer が非稼働 → systemctl status orenovpn-watch.timer"; fi
  if $S test -x /usr/local/sbin/orenovpn-watch; then pass "監視スクリプト配置あり"; else bad "/usr/local/sbin/orenovpn-watch が無い（make setup 再実行）"; fi
  # 送信の実体。これが無いと監視もクライアント通知も「黙って」全滅する。
  if $S test -x /usr/local/sbin/orenovpn-notify; then pass "通知スクリプト(orenovpn-notify) 配置あり"; else bad "/usr/local/sbin/orenovpn-notify が無い → メールが一切送られません（make sync-scripts）"; fi
  SMTP_MODE="$(getenv SMTP_MODE)"; SMTP_MODE="${SMTP_MODE:-relay}"
  if [ "$SMTP_MODE" = "local" ]; then
    if command -v sendmail >/dev/null 2>&1 || [ -x /usr/sbin/sendmail ] || [ -x /usr/sbin/dma ]; then
      pass "ローカルMTA(dma/sendmail) 配置あり"
    else
      wrn "sendmail(dma) が無い（ローカルMTAモードだがメール通知不可）"
    fi
    if $S ss -ltn 2>/dev/null | grep -E ':25\b' | grep -qvE '127\.0\.0\.1:25|\[::1\]:25'; then
      wrn "外部から到達可能な :25 待受あり（中継リスク・localhost のみのはず）"
    else
      pass "外部SMTP待受なし（中継なし）"
    fi
  else
    if $S test -f /etc/msmtprc; then pass "msmtp 設定あり"; else wrn "/etc/msmtprc が無い（メール通知不可）"; fi
  fi
  # SSH ログイン成功の通知（env 未設定の既存サーバーは watch.sh 側の既定 ON と同じ扱い）
  SSHLOGIN="$(getenv ENABLE_SSH_LOGIN_ALERT)"
  if [ "${SSHLOGIN:-true}" = "true" ]; then
    pass "SSH ログイン成功の通知 有効"
    IGN="$(getenv ALERT_SSH_LOGIN_IGNORE_IPS)"
    if [ -n "$IGN" ]; then echo "[INFO] SSH ログイン通知の除外 IP: ${IGN}"; fi
  else
    echo "[INFO] SSH ログイン成功の通知は無効（ENABLE_SSH_LOGIN_ALERT!=true）"
  fi
  # クライアントの作成/削除の通知（env 未設定の既存サーバーは既定 ON と同じ扱い）
  CLICHG="$(getenv ENABLE_CLIENT_CHANGE_ALERT)"
  if [ "${CLICHG:-true}" = "true" ]; then
    pass "クライアント作成/削除の通知 有効"
  else
    echo "[INFO] クライアント作成/削除の通知は無効（ENABLE_CLIENT_CHANGE_ALERT!=true）"
  fi
  BLOCKLIST="$(getenv ALERT_BLOCKLIST_URL)"
  if [ -n "$BLOCKLIST" ]; then
    if $S ipset list orenovpn_blocklist >/dev/null 2>&1; then pass "出口ブロックリスト(ipset) 配置あり"; else wrn "orenovpn_blocklist が未ロード"; fi
    if $S iptables -t nat -S PREROUTING 2>/dev/null | grep -q 'orenovpn-egress'; then
      pass "出口 LOG ルール(nat PREROUTING) 設定あり"
    else
      wrn "出口 LOG ルールが無い（sudo systemctl restart orenovpn-fwlog で適用）"
    fi
    # 旧方式が残っていると戻り通信まで一致して誤検知が大量に出る
    if $S iptables -S ufw-before-forward 2>/dev/null | grep -q 'orenovpn-egress'; then
      bad "旧方式の出口 LOG ルール(ufw-before-forward)が残存（戻り通信を誤検知）→ sudo /usr/local/sbin/setup.sh"
    fi
    # ブロックリストに VPN サブネットの除外(nomatch)が入っているか
    if $S ipset list orenovpn_blocklist 2>/dev/null | grep -q 'nomatch'; then
      pass "ブロックリストに VPN サブネットの除外(nomatch)あり"
    else
      wrn "VPN サブネットが除外されていない（private 範囲を含むリストでは誤検知の原因）→ sudo /usr/local/sbin/orenovpn-egress-refresh"
    fi
    n="$($S ipset list orenovpn_blocklist 2>/dev/null | grep -c '^[0-9]')"
    echo "[INFO] ブロックリスト登録数: ${n:-0}"
  fi
  last="$($S systemctl show -p ExecMainStatus --value orenovpn-watch.service 2>/dev/null || echo '')"
  if [ -n "$last" ]; then echo "[INFO] 監視の直近実行ステータス: ${last}"; fi
else
  echo "[INFO] 通信監視は無効（ENABLE_TRAFFIC_ALERT!=true）"
fi

# 6. アクセス先の記録（有効時のみ点検）
#    DNS は待受を誤るとオープンリゾルバ（増幅攻撃の踏み台）になるため必ず確認する。
ACCESSLOG="$(getenv ENABLE_ACCESS_LOG)"
DNSLOG="$(getenv ENABLE_DNS_LOGGING)"
if [ "$ACCESSLOG" = "true" ] || [ "$DNSLOG" = "true" ]; then
  if $S test -x /usr/local/sbin/orenovpn-logs; then
    pass "記録参照ツール配置あり（make access-log / make dns-log）"
  else
    wrn "/usr/local/sbin/orenovpn-logs が無い（make setup を再実行）"
  fi
  if $S test -f /etc/systemd/journald.conf.d/orenovpn-logs.conf; then
    pass "記録の保存上限を設定済み（journald）"
  else
    wrn "journald の保存上限が未設定（ディスクを消費し続ける恐れ）→ sudo /usr/local/sbin/setup.sh"
  fi
fi
if [ "$ACCESSLOG" = "true" ]; then
  if $S iptables -t nat -S PREROUTING 2>/dev/null | grep -q 'orenovpn-dst'; then
    pass "宛先記録ルール(nat PREROUTING) 設定あり"
  else
    bad "宛先記録が有効なのにルールが無い（何も記録されていない）→ sudo systemctl restart orenovpn-fwlog"
  fi
fi
if [ "$DNSLOG" = "true" ]; then
  if $S systemctl is-active --quiet unbound 2>/dev/null; then pass "unbound 稼働中"; else bad "unbound が非稼働 → journalctl -u unbound"; fi
  # UDP だけでなく TCP も見る（DNS は TCP でも待受する。片方だけ外部に開いていても
  # オープンリゾルバになる）。ss は指定するプロトコルによって Netid 列の有無が変わるため、
  # 列番号で拾うと取り違える（`ss -uln` には Netid 列が無く $5 は Peer 側）。
  # 列位置に依存せず ":53" で終わるフィールドをすべて拾う。
  L53="$($S ss -lunt 2>/dev/null | awk 'NR > 1 {for (i = 1; i <= NF; i++) if ($i ~ /:53$/) print $i}' | sort -u | tr '\n' ' ')"
  # 許可リスト方式で判定する（localhost と VPN 内アドレスのみ許可）。
  # ワイルドカードやグローバル IP に限らず、想定外の待受は原則すべて拒否する。
  L53BAD=""
  for a in $L53; do
    case "$a" in
      127.0.0.*:53|'[::1]:53') ;;
      "${SRVADDR}:53") ;;
      "[${SRV6}]:53") [ -n "$SRV6" ] || L53BAD="${L53BAD}${a} " ;;
      *) L53BAD="${L53BAD}${a} " ;;
    esac
  done
  if $S iptables -t nat -S PREROUTING 2>/dev/null | grep -qE 'dport 53 -j DNAT'; then
    DNSDNAT=yes
  else
    DNSDNAT=no
  fi
  if [ -n "$L53BAD" ]; then
    bad "DNS が許可外のアドレスで待受＝オープンリゾルバの恐れ: ${L53BAD}→ sudo /usr/local/sbin/setup.sh
       （許可されるのは localhost と VPN 内アドレス ${SRVADDR}${SRV6:+ / [${SRV6}]} のみ）"
  elif [ -n "$L53" ]; then
    pass "DNS 待受は VPN 内/localhost のみ: ${L53}"
  elif [ "$DNSDNAT" = yes ]; then
    # DNAT だけ入って待受が無い＝クライアントの名前解決が全滅する状態
    bad "53 番の待受が無いのに DNS の DNAT が入っている（クライアントの名前解決が全滅）
       → journalctl -u unbound で原因を確認。応急処置は次の2つのいずれか:
         sudo systemctl restart unbound && sudo systemctl restart orenovpn-fwlog
         make configure-logging ACCESS_LOG=on DNS_LOG=off   # DNS 記録をやめる"
  else
    wrn "53 番の待受が無い（unbound の設定を確認）"
  fi
  if [ "$DNSDNAT" = yes ]; then
    pass "DNS 強制転送(DNAT) 設定あり"
  else
    wrn "DNS の DNAT が無い（端末が別のリゾルバを使うと名前が記録されない）"
  fi
fi

echo "== 結果: OK=${ok} WARN=${warn} FAIL=${fail} =="
[ "$fail" -eq 0 ] || { echo "→ FAIL があります。上の指示に従って対処してください。"; exit 1; }
