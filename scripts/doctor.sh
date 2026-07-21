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
  if [ "$CRL" = "true" ]; then
    if $S test -f /etc/swanctl/x509crl/orenovpn.crl; then pass "CRL 配置あり（失効チェック有効）"; else wrn "CRL 未配置（enable_cert_revocation の設定を確認）"; fi
  fi
  active_sas="$($S swanctl --list-sas 2>/dev/null | grep -c ESTABLISHED)"
  echo "[INFO] 確立中の IKE_SA: ${active_sas:-0}"
elif [ "$PROTO" = "wireguard" ]; then
  if $S wg show 2>/dev/null | grep -q interface; then pass "WireGuard(wg0) 稼働中"; else bad "WireGuard が非稼働 → systemctl status wg-quick@wg0"; fi
  if [ -n "$WGPORT" ] && $S ss -uln 2>/dev/null | grep -q ":${WGPORT} "; then pass "UDP ${WGPORT} LISTEN"; else bad "UDP ${WGPORT:-?} が LISTEN していない"; fi
  peers="$($S wg show 2>/dev/null | grep -c peer)"
  echo "[INFO] 登録ピア数: ${peers:-0}"
fi

# 5. 通信監視・警告（ENABLE_TRAFFIC_ALERT=true のときのみ点検）
ALERT="$(getenv ENABLE_TRAFFIC_ALERT)"
if [ "$ALERT" = "true" ]; then
  if $S systemctl is-active --quiet orenovpn-watch.timer 2>/dev/null; then pass "監視 timer(orenovpn-watch) 稼働中"; else bad "orenovpn-watch.timer が非稼働 → systemctl status orenovpn-watch.timer"; fi
  if $S test -x /usr/local/sbin/orenovpn-watch; then pass "監視スクリプト配置あり"; else bad "/usr/local/sbin/orenovpn-watch が無い（make setup 再実行）"; fi
  SMTP_MODE="$(getenv SMTP_MODE)"; SMTP_MODE="${SMTP_MODE:-relay}"
  if [ "$SMTP_MODE" = "local" ]; then
    if command -v sendmail >/dev/null 2>&1; then pass "ローカルMTA(dma/sendmail) 配置あり"; else wrn "sendmail(dma) が無い（ローカルMTAモードだがメール通知不可）"; fi
    if $S ss -ltn 2>/dev/null | grep -E ':25\b' | grep -qvE '127\.0\.0\.1:25|\[::1\]:25'; then
      wrn "外部から到達可能な :25 待受あり（中継リスク・localhost のみのはず）"
    else
      pass "外部SMTP待受なし（中継なし）"
    fi
  else
    if $S test -f /etc/msmtprc; then pass "msmtp 設定あり"; else wrn "/etc/msmtprc が無い（メール通知不可）"; fi
  fi
  BLOCKLIST="$(getenv ALERT_BLOCKLIST_URL)"
  if [ -n "$BLOCKLIST" ]; then
    if $S ipset list orenovpn_blocklist >/dev/null 2>&1; then pass "出口ブロックリスト(ipset) 配置あり"; else wrn "orenovpn_blocklist が未ロード"; fi
    if $S grep -q 'orenovpn-egress' /etc/ufw/before.rules 2>/dev/null; then pass "出口 LOG ルール(before.rules) 設定あり"; else wrn "before.rules に出口 LOG ルールが無い"; fi
    n="$($S ipset list orenovpn_blocklist 2>/dev/null | grep -c '^[0-9]')"
    echo "[INFO] ブロックリスト登録数: ${n:-0}"
  fi
  last="$($S systemctl show -p ExecMainStatus --value orenovpn-watch.service 2>/dev/null || echo '')"
  if [ -n "$last" ]; then echo "[INFO] 監視の直近実行ステータス: ${last}"; fi
else
  echo "[INFO] 通信監視は無効（ENABLE_TRAFFIC_ALERT!=true）"
fi

echo "== 結果: OK=${ok} WARN=${warn} FAIL=${fail} =="
[ "$fail" -eq 0 ] || { echo "→ FAIL があります。上の指示に従って対処してください。"; exit 1; }
