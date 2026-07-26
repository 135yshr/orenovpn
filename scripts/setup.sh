#!/usr/bin/env bash
#
# orenovpn サーバー構成スクリプト（フェーズ2）
#   `make setup` が SSH 経由でサーバーに転送し sudo 実行する。
#   VPN_PROTOCOL に応じて WireGuard または IKEv2/IPsec を構成する。
#   何度でも再実行可能（冪等）。出力は端末に表示され、デバッグが容易。
#
#   設定値は /etc/orenovpn/orenovpn.env（cloud-init が生成）から読み込む。
#
set -euo pipefail

ENV_FILE=/etc/orenovpn/orenovpn.env
# shellcheck disable=SC1090
source "$ENV_FILE"

log() { echo "[orenovpn] $*"; }
die() { echo "[orenovpn] エラー: $*" >&2; exit 1; }

VPN_PROTOCOL="${VPN_PROTOCOL:-wireguard}"
# 証明書失効(CRL)を有効化するか（IKEv2のみ）。既定は true。
#   漏洩・端末紛失時に接続を止められないのは事故なので、既定で失効可能にしておく。
#   未設定の既存インスタンスでも true 扱いにして CA DB / CRL を用意する（fail-open の
#   ため既存クライアントはロックアウトされないが、失効有効化より前に発行した証明書は
#   CA DB 未登録のため失効できない = 作り直しが必要）。
ENABLE_CERT_REVOCATION="${ENABLE_CERT_REVOCATION:-true}"
: "${ENABLE_TRAFFIC_ALERT:=false}"
: "${ALERT_EMAIL:=}"
: "${SMTP_HOST:=}"
: "${SMTP_PORT:=587}"
: "${SMTP_USER:=}"
: "${SMTP_PASSWORD:=}"
: "${SMTP_AUTH:=on}"
: "${SMTP_MODE:=relay}"
: "${MAIL_FROM:=}"
: "${ALERT_BLOCKLIST_URL:=}"
# --- アクセス先の記録（既定 OFF・オプトイン）--------------------------------
# ENABLE_ACCESS_LOG  : VPN クライアントの新規接続の宛先(IP/ポート)を記録する
# ENABLE_DNS_LOGGING : サーバー上に unbound を立て、VPN の DNS 問い合わせ（ドメイン名）を記録する
# LOG_RETENTION_DAYS : 記録の保存日数（journald の MaxRetentionSec に反映）
: "${ENABLE_ACCESS_LOG:=false}"
: "${ENABLE_DNS_LOGGING:=false}"
: "${LOG_RETENTION_DAYS:=14}"
case "${LOG_RETENTION_DAYS}" in ''|*[!0-9]*) LOG_RETENTION_DAYS=14 ;; esac

# 通信監視・警告の構成を関数化。通常フローの section 8 と `setup.sh alerts` の両方から呼ぶ。
configure_traffic_alert() {
if [ "${ENABLE_TRAFFIC_ALERT}" = "true" ]; then
  if [ -z "${ALERT_EMAIL}" ]; then
    log "警告: ENABLE_TRAFFIC_ALERT=true だが ALERT_EMAIL 未設定。通知は送られません"
  elif [ "${SMTP_MODE}" != "local" ] && [ -z "${SMTP_HOST}" ]; then
    log "警告: relay モードだが SMTP_HOST 未設定。通知は送られません（make configure-alerts で設定）"
  fi

  # MTA 導入（モード依存）。relay は msmtp、local は dma（待受なし・直接配送）。
  export DEBIAN_FRONTEND=noninteractive
  if [ "${SMTP_MODE}" = "local" ]; then
    # ローカル MTA(dma): 待受ソケット無し＝中継なし・ローカル投函のみ。宛先MXへ直接配送。
    if ! command -v dma >/dev/null 2>&1; then
      echo "dma dma/relayhost string" | debconf-set-selections 2>/dev/null || true
      echo "dma dma/mailname string $(hostname -f 2>/dev/null || hostname)" | debconf-set-selections 2>/dev/null || true
      apt-get update -y || true
      apt-get install -y dma || log "dma の導入に失敗"
    fi
  else
    command -v msmtp >/dev/null 2>&1 || { apt-get update -y || true; apt-get install -y msmtp || log "msmtp の導入に失敗"; }
  fi

  if [ "${SMTP_MODE}" = "local" ]; then
    # dma: smarthost 未設定＝直接配送。待受なしのため中継リスクなし。
    # ディレクトリとファイルのモードは明示する。dma は root 以外からも投函でき、
    # 設定が読めないと "can not open config: Permission denied" で送信できない
    # （呼び出し元の umask に依存させると 0700/0600 になり壊れる）。
    install -d -m 0755 -o root -g root /etc/dma
    {
      echo "# orenovpn が生成。SMARTHOST 未設定＝宛先MXへ直接配送。"
      echo "# dma は待受ソケットを持たず、ローカル投函のみ処理する（中継しない）。"
      echo "MAILNAME $(hostname -f 2>/dev/null || hostname)"
    } >/etc/dma/dma.conf
    chmod 0644 /etc/dma/dma.conf
    chown root:root /etc/dma/dma.conf
    log "ローカル MTA(dma) を構成（直接配送・中継なし・localhost のみ）"
  else
    # msmtp 送信設定（パスワードを含むため 0600 root:root）
    umask 077
    {
      echo "# orenovpn が生成。SMTP リレー設定（送信専用）。手動編集は make setup で上書きされます。"
      echo "defaults"
      echo "tls            on"
      echo "tls_starttls   on"
      echo "logfile        /var/log/msmtp.log"
      echo ""
      echo "account        orenovpn"
      echo "host           ${SMTP_HOST}"
      echo "port           ${SMTP_PORT}"
      echo "from           ${SMTP_USER:-$ALERT_EMAIL}"
      if [ "${SMTP_AUTH}" = "off" ]; then
        echo "auth           off"
      else
        echo "auth           on"
        echo "user           ${SMTP_USER}"
        echo "password       ${SMTP_PASSWORD}"
      fi
      echo ""
      echo "account default : orenovpn"
    } >/etc/msmtprc
    chmod 600 /etc/msmtprc
    chown root:root /etc/msmtprc
    umask 022
    log "msmtp（外部SMTPリレー）を構成"
  fi

  if [ ! -x /usr/local/sbin/orenovpn-watch ]; then
    log "警告: /usr/local/sbin/orenovpn-watch が無い（make setup で転送されます）"
  fi

  cat >/etc/systemd/system/orenovpn-watch.service <<'EOF'
[Unit]
Description=orenovpn traffic anomaly watch
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/orenovpn-watch
Nice=10
EOF

  cat >/etc/systemd/system/orenovpn-watch.timer <<'EOF'
[Unit]
Description=Run orenovpn-watch every 5 minutes

[Timer]
OnBootSec=3min
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now orenovpn-watch.timer >/dev/null 2>&1 || true
  log "通信監視を構成（orenovpn-watch.timer・5分毎）"

  # ---- 出口通信検知（悪性IPブロックリスト。ログのみ・ドロップしない）--------
  # ALERT_BLOCKLIST_URL 設定時のみ。ufw の before.rules に LOG ルールを冪等追記
  # （NAT と同じ方式）。ipset は ufw より先に復元する service で永続化する。
  if [ -n "${ALERT_BLOCKLIST_URL}" ]; then
    cat >/usr/local/sbin/orenovpn-egress-refresh <<'EOS'
#!/usr/bin/env bash
# orenovpn-egress-refresh : 悪性IPブロックリストを取得し ipset を更新する。
#   setup.sh が生成。orenovpn-egress-refresh.timer から毎日実行される。冪等。
set -euo pipefail
ENV_FILE=/etc/orenovpn/orenovpn.env
# shellcheck disable=SC1090,SC1091
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${ALERT_BLOCKLIST_URL:=}"
: "${WG_SUBNET_V4:=10.66.66.0/24}"
SET=orenovpn_blocklist
PERSIST=/etc/orenovpn/blocklist.ipset
log() { printf '[egress-refresh] %s\n' "$*" >&2; }

# 自分の VPN サブネットは検知対象から除外する。公開ブロックリスト（FireHOL level1 等）は
# private 範囲（10.0.0.0/8 など）を含むため、除外しないと VPN 内アドレスが常に「悪性」
# 判定になり、誤検知が大量に出る（実機で 5 分間に 14,188 件を記録した）。
# hash:net は最長一致で nomatch が優先されるため、より具体的な VPN サブネットを
# nomatch として入れておけばよい。
add_exceptions() {
  ipset add -exist "$1" "$WG_SUBNET_V4" nomatch 2>/dev/null || true
}

ipset create -exist "$SET" hash:net family inet maxelem 262144
add_exceptions "$SET"

if [ -z "$ALERT_BLOCKLIST_URL" ]; then
  log "ALERT_BLOCKLIST_URL 未設定。空リストを維持"
  exit 0
fi

tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT
if ! curl -fsS --max-time 60 "$ALERT_BLOCKLIST_URL" -o "$tmpfile"; then
  log "ブロックリスト取得失敗: $ALERT_BLOCKLIST_URL（既存セットを維持）"
  exit 0
fi

ipset create -exist "${SET}_tmp" hash:net family inet maxelem 262144
ipset flush "${SET}_tmp"
count=0
while read -r line; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | tr -d '[:space:]')"
  [ -n "$line" ] || continue
  case "$line" in
    *[!0-9./]*) continue ;;
  esac
  if ipset add -exist "${SET}_tmp" "$line" 2>/dev/null; then
    count=$((count + 1))
  fi
done < "$tmpfile"
add_exceptions "${SET}_tmp"
ipset swap "${SET}_tmp" "$SET"
ipset destroy "${SET}_tmp"
ipset save "$SET" >"$PERSIST"
log "ブロックリスト更新完了: ${count} 件"
EOS
    chmod 0755 /usr/local/sbin/orenovpn-egress-refresh

    # ipset を先に作成・投入（この後の ufw reload が match-set を解決できるように）
    /usr/local/sbin/orenovpn-egress-refresh || log "初回ブロックリスト取得に失敗（timer で再試行）"

    # 起動時に ufw より先に ipset を復元
    cat >/etc/systemd/system/orenovpn-ipset-restore.service <<'EOF'
[Unit]
Description=orenovpn restore blocklist ipset before ufw
DefaultDependencies=no
Before=ufw.service network-pre.target
ConditionPathExists=/etc/orenovpn/blocklist.ipset

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ipset restore -exist -f /etc/orenovpn/blocklist.ipset

[Install]
WantedBy=multi-user.target
EOF

    cat >/etc/systemd/system/orenovpn-egress-refresh.service <<'EOF'
[Unit]
Description=orenovpn egress blocklist refresh
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/orenovpn-egress-refresh
EOF

    cat >/etc/systemd/system/orenovpn-egress-refresh.timer <<'EOF'
[Unit]
Description=Refresh orenovpn egress blocklist daily

[Timer]
OnBootSec=5min
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # LOG ルールは nat PREROUTING 側（orenovpn-fwlog-apply）が入れる。
    # 旧方式（ufw-before-forward）は撤去する。理由は 2 つ:
    #   1. WireGuard では PostUp が FORWARD 先頭で ACCEPT するため一切発火しない
    #   2. 向きの限定が無く、戻り通信（宛先=VPN内アドレス）まで一致してしまう。
    #      公開ブロックリストは private 範囲を含むため、これが大量の誤検知になる
    remove_legacy_egress_rule

    systemctl daemon-reload
    systemctl enable orenovpn-ipset-restore.service >/dev/null 2>&1 || true
    systemctl enable --now orenovpn-egress-refresh.timer >/dev/null 2>&1 || true
    log "出口通信検知を有効化（nat PREROUTING の LOG・daily 更新）"
  else
    # ブロックリスト未設定 → 出口検知の後始末
    remove_legacy_egress_rule
    systemctl disable --now orenovpn-egress-refresh.timer >/dev/null 2>&1 || true
    systemctl disable orenovpn-ipset-restore.service >/dev/null 2>&1 || true
    ipset destroy orenovpn_blocklist >/dev/null 2>&1 || true
  fi
else
  if systemctl list-unit-files 2>/dev/null | grep -q orenovpn-watch.timer; then
    systemctl disable --now orenovpn-watch.timer >/dev/null 2>&1 || true
    log "通信監視を無効化（timer 停止）"
  fi
  remove_legacy_egress_rule
  systemctl disable --now orenovpn-egress-refresh.timer >/dev/null 2>&1 || true
  systemctl disable orenovpn-ipset-restore.service >/dev/null 2>&1 || true
  ipset destroy orenovpn_blocklist >/dev/null 2>&1 || true
fi
}

# 旧方式の出口検知ルール（ufw-before-forward の LOG）を撤去する。
#   `ufw reload` は使わない（before.rules を noflush で再適用するため、前置している
#   orenovpn-nat ブロックの MASQUERADE が二重登録される）。実チェーンから直接消す。
remove_legacy_egress_rule() {
  local removed=0
  if grep -q 'orenovpn-egress' /etc/ufw/before.rules 2>/dev/null; then
    sed -i '/orenovpn-egress/d' /etc/ufw/before.rules
    removed=1
  fi
  while iptables -D ufw-before-forward -m set --match-set orenovpn_blocklist dst \
      -j LOG --log-prefix "orenovpn-egress: " --log-level 4 >/dev/null 2>&1; do
    removed=1
  done
  [ "$removed" = 1 ] && log "旧方式の出口検知ルール(ufw-before-forward)を撤去" || true
}

# サブコマンド: `setup.sh alerts` で監視設定だけを冪等に再構成する
# （make configure-alerts が既存サーバーへアラート設定を反映する際に使用）。
# VPN 本体（パッケージ再導入・ufw リセット等）は実行しない。
if [ "${1:-}" = "alerts" ]; then
  export DEBIAN_FRONTEND=noninteractive
  if [ "${ENABLE_TRAFFIC_ALERT}" = "true" ]; then
    command -v ipset >/dev/null 2>&1 || { apt-get update -y || true; apt-get install -y ipset || true; }
  fi
  configure_traffic_alert
  log "アラート設定を再構成しました（alerts モード）"
  exit 0
fi

# -----------------------------------------------------------------------------
# 0. 実行環境の前提チェック（VPN 経由の SSH では実行できない）
#
#   このスクリプトは途中で strongSwan / wg-quick を再起動する。VPN に接続した端末から
#   SSH している場合、SSH 自体がトンネルを通っているため、その瞬間に接続が切れて
#   スクリプトが中断し、サーバーが中途半端な構成で残る。
#   （実機で "Read from remote host: Can't assign requested address" が発生した）
#   必ず VPN を切断してから実行する。detach 実行など事情がある場合のみ
#   ORENOVPN_ALLOW_VPN_SETUP=1 で上書きできる。
# -----------------------------------------------------------------------------
if [ "${ORENOVPN_ALLOW_VPN_SETUP:-0}" != "1" ]; then
  SSH_PEER="$(printf '%s' "${SSH_CONNECTION:-${SSH_CLIENT:-}}" | awk '{print $1}')"
  if [ -n "${SSH_PEER}" ]; then
    case "${SSH_PEER}" in
      "${WG_ADDRESS_V4%.*}."* | "${WG_ADDRESS_V6%::*}::"*)
        die "VPN 経由の SSH（接続元 ${SSH_PEER}）では実行できません。
   途中で VPN サービスを再起動するため、この SSH 接続ごと切れて構成が中断します。
   端末の VPN を切断してから make setup を実行してください
   （どうしても必要な場合のみ ORENOVPN_ALLOW_VPN_SETUP=1 を付けて実行）。"
        ;;
    esac
  fi
fi
# -----------------------------------------------------------------------------
# 1. WAN インターフェイスとパブリック IP を検出し env に保存
# -----------------------------------------------------------------------------
WAN_IF="$(ip -4 route show default | awk '{print $5; exit}')"
SERVER_IP="$(ip -4 addr show "$WAN_IF" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
log "WAN=${WAN_IF} server_ip=${SERVER_IP} protocol=${VPN_PROTOCOL}"
if ! grep -q '^WG_WAN_IFACE=' "$ENV_FILE"; then
  {
    echo "WG_WAN_IFACE=\"${WAN_IF}\""
    echo "WG_ENDPOINT_IP=\"${SERVER_IP}\""
    echo "SERVER_IP=\"${SERVER_IP}\""
  } >> "$ENV_FILE"
fi

# -----------------------------------------------------------------------------
# 1.5 swap 確保（512MB プランで apt がメモリ不足で失敗しないように）
# -----------------------------------------------------------------------------
if [ ! -f /swapfile ] && ! swapon --show | grep -q '/swapfile'; then
  log "swap(2G) を作成中..."
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  log "swap 有効化"
fi

# -----------------------------------------------------------------------------
# 1.7 Debian 既定 nftables を無効化（ufw と競合し 22 番以外を全ドロップするため）
#     /etc/nftables.conf の "table inet filter"(input policy drop) が nftables.service
#     で読み込まれ、ufw の許可ルールより優先して VPN ポート等を落としてしまう。
#     ファイアウォールは ufw に一本化する（再起動後も復活しないよう service を無効化）。
# -----------------------------------------------------------------------------
systemctl disable --now nftables >/dev/null 2>&1 || true
nft delete table inet filter >/dev/null 2>&1 || true
log "Debian 既定 nftables を無効化（ufw に一本化）"

# -----------------------------------------------------------------------------
# 2. パッケージ導入（プロトコル別）
# -----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
log "パッケージ情報を更新中..."
apt-get update -qq
PKGS="iptables ufw curl ca-certificates"
case "$VPN_PROTOCOL" in
  wireguard) PKGS="$PKGS wireguard wireguard-tools qrencode" ;;
  ikev2)     PKGS="$PKGS strongswan strongswan-pki strongswan-swanctl libcharon-extra-plugins libstrongswan-extra-plugins openssl uuid-runtime" ;;
  *)         echo "不明な VPN_PROTOCOL: $VPN_PROTOCOL" >&2; exit 1 ;;
esac
[ "${ENABLE_FAIL2BAN}" = "true" ]     && PKGS="$PKGS fail2ban"
[ "${ENABLE_AUTO_UPDATES}" = "true" ] && PKGS="$PKGS unattended-upgrades apt-listchanges"
[ "${ENABLE_DNS_LOGGING}" = "true" ]  && PKGS="$PKGS unbound"

if [ "${ENABLE_TRAFFIC_ALERT}" = "true" ]; then
  PKGS="$PKGS ipset"
fi
log "パッケージを導入中: ${PKGS}"
# shellcheck disable=SC2086
apt-get install -y -qq $PKGS
log "パッケージ導入完了"

# -----------------------------------------------------------------------------
# 3. カーネルパラメータ（IP 転送 + 堅牢化）
# -----------------------------------------------------------------------------
cat > /etc/sysctl.d/99-orenovpn.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.all.log_martians=1
net.ipv6.conf.all.accept_redirects=0
net.ipv4.tcp_syncookies=1
kernel.kptr_restrict=2
EOF
sysctl --system >/dev/null

# -----------------------------------------------------------------------------
# 4. プロトコル別の構成
# -----------------------------------------------------------------------------
setup_wireguard() {
  local WG_IF=wg0 WG_CONF="/etc/wireguard/wg0.conf"
  umask 077
  mkdir -p /etc/wireguard
  if [ ! -f /etc/wireguard/server_private.key ]; then
    wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
    log "WireGuard サーバー鍵を生成"
  fi
  local SERVER_PRIV; SERVER_PRIV="$(cat /etc/wireguard/server_private.key)"
  local V4_PREFIX="${WG_SUBNET_V4##*/}"
  local ADDRESS_LINE="${WG_ADDRESS_V4}/${V4_PREFIX}"
  # 転送ルールは「トンネル→外」「トンネル内同士」「確立済みの戻り」だけに限定する。
  #   旧実装は `-o %i -j ACCEPT` を FORWARD の先頭（ufw のチェーンより前）に置き、
  #   MASQUERADE も -s 無しだったため、外部から「宛先=VPN サブネット」のパケットが
  #   VPN 認証なしにトンネルへ転送され、戻りまで NAT されて成立していた。
  local POSTUP="iptables -I FORWARD 1 -i %i -o ${WAN_IF} -j ACCEPT; iptables -I FORWARD 2 -i %i -o %i -j ACCEPT; iptables -I FORWARD 3 -i ${WAN_IF} -o %i -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; iptables -t nat -I POSTROUTING 1 -s ${WG_SUBNET_V4} -o ${WAN_IF} -j MASQUERADE"
  local POSTDOWN="iptables -D FORWARD -i %i -o ${WAN_IF} -j ACCEPT; iptables -D FORWARD -i %i -o %i -j ACCEPT; iptables -D FORWARD -i ${WAN_IF} -o %i -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; iptables -t nat -D POSTROUTING -s ${WG_SUBNET_V4} -o ${WAN_IF} -j MASQUERADE"
  if [ "${WG_ENABLE_IPV6}" = "true" ]; then
    local V6_PREFIX="${WG_SUBNET_V6##*/}"
    ADDRESS_LINE="${ADDRESS_LINE}, ${WG_ADDRESS_V6}/${V6_PREFIX}"
    POSTUP="${POSTUP}; ip6tables -I FORWARD 1 -i %i -o ${WAN_IF} -j ACCEPT; ip6tables -I FORWARD 2 -i %i -o %i -j ACCEPT; ip6tables -I FORWARD 3 -i ${WAN_IF} -o %i -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; ip6tables -t nat -I POSTROUTING 1 -s ${WG_SUBNET_V6} -o ${WAN_IF} -j MASQUERADE"
    POSTDOWN="${POSTDOWN}; ip6tables -D FORWARD -i %i -o ${WAN_IF} -j ACCEPT; ip6tables -D FORWARD -i %i -o %i -j ACCEPT; ip6tables -D FORWARD -i ${WAN_IF} -o %i -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; ip6tables -t nat -D POSTROUTING -s ${WG_SUBNET_V6} -o ${WAN_IF} -j MASQUERADE"
  fi
  if [ ! -f "$WG_CONF" ]; then
    cat > "$WG_CONF" <<EOF
# orenovpn WireGuard サーバー設定（クライアントは 'vpn-client' で管理）
# orenovpn-fw-v2: 転送/NAT を VPN サブネットと方向で限定（緩いルールへ戻さないこと）
[Interface]
Address = ${ADDRESS_LINE}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
PostUp = ${POSTUP}
PostDown = ${POSTDOWN}
EOF
    chmod 600 "$WG_CONF"
    log "wg0.conf を生成"
  elif ! grep -qF 'orenovpn-fw-v2' "$WG_CONF"; then
    # 既存インスタンスの移行: 旧い全許可ルールを実チェーンから外してから書き換える。
    # （先に conf を書き換えると PostDown が新ルール用になり、旧ルールが残る）
    log "既存 wg0.conf の転送/NAT ルールを更新（外部からトンネルへ入れる緩いルールを撤去）"
    systemctl stop "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
    # 同一ルールが重複登録されている可能性があるため複数回消す
    for _ in 1 2 3 4 5; do
      iptables -D FORWARD -i "$WG_IF" -j ACCEPT >/dev/null 2>&1 || true
      iptables -D FORWARD -o "$WG_IF" -j ACCEPT >/dev/null 2>&1 || true
      iptables -t nat -D POSTROUTING -o "${WAN_IF}" -j MASQUERADE >/dev/null 2>&1 || true
      ip6tables -D FORWARD -i "$WG_IF" -j ACCEPT >/dev/null 2>&1 || true
      ip6tables -D FORWARD -o "$WG_IF" -j ACCEPT >/dev/null 2>&1 || true
      ip6tables -t nat -D POSTROUTING -o "${WAN_IF}" -j MASQUERADE >/dev/null 2>&1 || true
    done
    sed -i -e '/^PostUp *=/d' -e '/^PostDown *=/d' -e '/^# orenovpn-fw-v2/d' "$WG_CONF"
    sed -i "/^ListenPort *=/a PostUp = ${POSTUP}\nPostDown = ${POSTDOWN}\n# orenovpn-fw-v2: 転送/NAT を VPN サブネットと方向で限定（緩いルールへ戻さないこと）" "$WG_CONF"
    chmod 600 "$WG_CONF"
  fi
  systemctl enable --now "wg-quick@${WG_IF}"
  # umask を戻す（戻さないと以降で作るディレクトリ/ファイルが 0700/0600 になり、
  # root 以外が読む必要のあるもの（例: /etc/dma）が壊れる）
  umask 022
  log "WireGuard を起動"
}

setup_ikev2() {
  local PKI=/etc/orenovpn/pki
  mkdir -p "$PKI"; chmod 700 "$PKI"
  umask 077

  # --- CA（初回のみ生成）。strongSwan の厳格な検証を通すため keyCertSign/cRLSign と
  #     subjectKeyIdentifier を必ず付与する（これが無いと "no trusted public key" になる）
  if [ ! -f "$PKI/ca-key.pem" ]; then
    openssl genrsa -out "$PKI/ca-key.pem" 4096
    openssl req -x509 -new -nodes -key "$PKI/ca-key.pem" -sha256 -days 3650 \
      -subj "/CN=orenovpn CA" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -addext "subjectKeyIdentifier=hash" \
      -out "$PKI/ca-cert.pem"
    log "IKEv2 CA を生成"
  fi

  # --- 証明書失効(CRL)基盤（オプトイン・冪等）。openssl ca での発行/失効/CRL生成に必要。
  #     これが無いと ikev2-client の失効機能が使えない。fail-open 運用（失効した証明書
  #     のみ拒否し、CRL 期限切れでも有効クライアントはロックアウトしない）。
  if [ "${ENABLE_CERT_REVOCATION}" = "true" ]; then
    [ -f "$PKI/index.txt" ] || : > "$PKI/index.txt"
    [ -f "$PKI/serial" ]    || echo 1000 > "$PKI/serial"
    [ -f "$PKI/crlnumber" ] || echo 1000 > "$PKI/crlnumber"
    mkdir -p "$PKI/newcerts"
    cat > "$PKI/ca.cnf" <<CACNF
[ca]
default_ca = CA_default
[CA_default]
dir              = ${PKI}
database         = ${PKI}/index.txt
new_certs_dir    = ${PKI}/newcerts
serial           = ${PKI}/serial
crlnumber        = ${PKI}/crlnumber
certificate      = ${PKI}/ca-cert.pem
private_key      = ${PKI}/ca-key.pem
default_md       = sha256
default_crl_days = 3650
policy           = pol_any
[pol_any]
commonName = supplied
CACNF
  fi

  # --- サーバー証明書（SAN=IP + serverAuth + SKI/AKI）。IP 変化時は作り直す
  if [ ! -f "$PKI/server-cert.pem" ] || ! grep -q "${SERVER_IP}" "$PKI/server-san.txt" 2>/dev/null; then
    echo "${SERVER_IP}" > "$PKI/server-san.txt"
    openssl genrsa -out "$PKI/server-key.pem" 4096
    openssl req -new -key "$PKI/server-key.pem" -subj "/CN=${SERVER_IP}" -out "$PKI/server.csr"
    openssl x509 -req -in "$PKI/server.csr" -CA "$PKI/ca-cert.pem" -CAkey "$PKI/ca-key.pem" \
      -CAcreateserial -days 3650 -sha256 \
      -extfile <(printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:%s\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n' "${SERVER_IP}") \
      -out "$PKI/server-cert.pem"
    rm -f "$PKI/server.csr"
    log "IKEv2 サーバー証明書を生成 (SAN=IP:${SERVER_IP})"
  fi

  # --- swanctl へ証明書を配置
  mkdir -p /etc/swanctl/x509ca /etc/swanctl/x509 /etc/swanctl/private
  install -m600 "$PKI/ca-cert.pem"     /etc/swanctl/x509ca/ca.pem
  install -m600 "$PKI/server-cert.pem" /etc/swanctl/x509/server.pem
  install -m600 "$PKI/server-key.pem"  /etc/swanctl/private/server-key.pem

  # --- CRL を生成し swanctl に配置（失効チェック用）。空でも置いておく。
  if [ "${ENABLE_CERT_REVOCATION}" = "true" ]; then
    mkdir -p /etc/swanctl/x509crl
    if openssl ca -gencrl -config "$PKI/ca.cnf" -out "$PKI/crl.pem" 2>/dev/null; then
      install -m644 "$PKI/crl.pem" /etc/swanctl/x509crl/orenovpn.crl
      log "CRL を生成・配置（証明書失効チェック有効）"
    fi
  fi

  # --- swanctl/charon の未使用 agent プラグイン警告(CAP_SETUID)を抑制
  mkdir -p /etc/strongswan.d/charon
  echo 'agent { load = no }' > /etc/strongswan.d/charon/agent.conf

  # --- swanctl 接続定義（IKEv2 / 証明書認証 / ロードウォリア）
  # クライアントへ配布する DNS。名前解決を記録する場合は自前リゾルバ(unbound)を配る。
  # （IKEv2 はここを変えるだけで再接続時に反映される＝プロファイル作り直し不要）
  local DNS_SW
  if [ "${ENABLE_DNS_LOGGING}" = "true" ]; then
    DNS_SW="${WG_ADDRESS_V4}"
    [ "${WG_ENABLE_IPV6}" = "true" ] && DNS_SW="${DNS_SW}, ${WG_ADDRESS_V6}"
  else
    DNS_SW="$(echo "${WG_DNS}" | sed 's/,/, /g')"
  fi
  # IPv6 リーク対策: v6 有効時のみ ::/0 を提示し、v6 内部アドレスも配布する。
  # （v6 を提示するだけで配布しないと、端末のネイティブ v6 がトンネル外へ漏れる。
  #   逆に v6 無効時は ::/0 を一切提示しない＝端末に v6 経路を作らせない。）
  # アドレスプールは「サーバー自身のアドレス（${WG_ADDRESS_V4}）を含めない」こと。
  #   サブネットをそのまま渡すと strongSwan は先頭(.1)から払い出すため、
  #   ${WG_ADDRESS_V4}（DNS 記録用に lo へ付与している）とクライアントのリースが衝突し、
  #   「VPN は張れるがインターネットに出られない」状態になる:
  #     - クライアント自身の住所 = 配布された DNS サーバー → 名前解決できない
  #     - 戻り通信の宛先がサーバーのローカルアドレスになり、トンネルへ転送されない
  #   /24・/64 前提で 2 番目以降を割り当てる（swanctl の addrs は範囲指定に対応）。
  local POOL4_ADDRS POOL6_ADDRS
  POOL4_ADDRS="${WG_ADDRESS_V4%.*}.2-${WG_ADDRESS_V4%.*}.254"
  POOL6_ADDRS="${WG_ADDRESS_V6%::*}::2-${WG_ADDRESS_V6%::*}::ffff"
  local LOCAL_TS="0.0.0.0/0" POOL_REF="orenovpn_pool" POOL6_BLOCK=""
  if [ "${WG_ENABLE_IPV6}" = "true" ]; then
    LOCAL_TS="0.0.0.0/0, ::/0"
    POOL_REF="orenovpn_pool, orenovpn_pool6"
    # v4/v6 は別プールに分ける（swanctl の pool.addrs は 1 プール 1 アドレス族が確実。
    #  混在指定だと片方しか読み込まれず "no virtual IP found for %any6" になる）。
    POOL6_BLOCK="  orenovpn_pool6 {
    addrs = ${POOL6_ADDRS}
  }"
  fi
  cat > /etc/swanctl/swanctl.conf <<EOF
connections {
  orenovpn {
    version = 2
    proposals = aes256-sha256-modp2048,aes256gcm16-prfsha384-ecp384
    # 鍵ローテーション: IKE SA を 4 時間ごとに再生成。reauth ではなく rekey なので
    # iOS/macOS はセッションを維持したまま鍵を更新でき、再接続は発生しない。
    rekey_time = 14400
    # 全クライアントで UDP カプセル化(4500)を強制。非NATクライアントでも
    # ネイティブ ESP(IP proto 50) を必要とせず、UDP 500/4500 のみで通る。
    encap = yes
    pools = ${POOL_REF}
    local {
      auth = pubkey
      certs = server.pem
      id = ${SERVER_IP}
    }
    remote {
      auth = pubkey
      cacerts = ca.pem
    }
    children {
      orenovpn {
        local_ts = ${LOCAL_TS}
        # PFS: ESP 提案に DH 群(MODP2048=iOS の DH14 に一致)を含め、CHILD_SA を
        # 1 時間ごとに新しい鍵交換で再生成する。過去鍵が漏れても遡って復号されない。
        esp_proposals = aes256-sha256-modp2048,aes256gcm16-ecp384
        rekey_time = 3600
        dpd_action = clear
      }
    }
  }
}
pools {
  orenovpn_pool {
    addrs = ${POOL4_ADDRS}
    dns = ${DNS_SW}
  }
${POOL6_BLOCK}
}
EOF
  chmod 600 /etc/swanctl/swanctl.conf

  # NAT は ufw リセット後に適用する（apply_ikev2_nat を「5.ファイアウォール」で呼ぶ）。
  # ここで before.rules に書いても後段の `ufw --force reset` で消えてしまうため。

  # swanctl ベースのサービスを起動（Debian のパッケージ差異に備えて候補を順に試行）
  # 失敗を成功扱いにしない: 起動もロードもできなければ die して make setup を失敗させる。
  local started=""
  for svc in strongswan.service strongswan-swanctl.service strongswan; do
    if systemctl enable --now "$svc" >/dev/null 2>&1; then started="$svc"; break; fi
  done
  [ -n "$started" ] || die "strongSwan サービスを起動できませんでした（systemctl status strongswan を確認）"
  systemctl restart "$started"
  swanctl --load-all || die "swanctl --load-all に失敗しました（swanctl.conf/証明書を確認）"
  systemctl is-active --quiet "$started" || die "strongSwan が active になりません（journalctl -u strongswan を確認）"
  # umask を戻す（戻さないと以降で作るディレクトリ/ファイルが 0700/0600 になり、
  # root 以外が読む必要のあるもの（例: /etc/dma）が壊れる）
  umask 022
  log "IKEv2/IPsec (strongSwan) 構成完了 サービス=${started}"
}

# IKEv2 の NAT(MASQUERADE)＋転送許可を ufw に適用する。ufw のリセット後に呼ぶこと
# （before.rules は `ufw --force reset` でデフォルトへ戻るため、リセット前に書くと消える）。
apply_ikev2_nat() {
  # IPv4: VPN サブネット → WAN を MASQUERADE
  if ! grep -q 'orenovpn-nat' /etc/ufw/before.rules; then
    local tmp; tmp="$(mktemp)"
    {
      echo "# orenovpn-nat BEGIN"
      echo "*nat"
      echo ":POSTROUTING ACCEPT [0:0]"
      echo "-A POSTROUTING -s ${WG_SUBNET_V4} -o ${WAN_IF} -j MASQUERADE"
      echo "COMMIT"
      echo "# orenovpn-nat END"
      cat /etc/ufw/before.rules
    } > "$tmp"
    mv "$tmp" /etc/ufw/before.rules
  fi
  # IPv6: v6 有効時は before6.rules にも NAT66。トンネル内 v6 をサーバーの v6 経由で
  # 送出（v6 出口が無ければ破棄＝トンネル外へ漏れない）。
  if [ "${WG_ENABLE_IPV6}" = "true" ] && ! grep -q 'orenovpn-nat' /etc/ufw/before6.rules 2>/dev/null; then
    local tmp6; tmp6="$(mktemp)"
    {
      echo "# orenovpn-nat BEGIN"
      echo "*nat"
      echo ":POSTROUTING ACCEPT [0:0]"
      echo "-A POSTROUTING -s ${WG_SUBNET_V6} -o ${WAN_IF} -j MASQUERADE"
      echo "COMMIT"
      echo "# orenovpn-nat END"
      cat /etc/ufw/before6.rules
    } > "$tmp6"
    mv "$tmp6" /etc/ufw/before6.rules
  fi

  # 転送は「IPsec SA を通ってきた VPN サブネット発」と「その戻り」だけを許可する。
  #   旧実装は DEFAULT_FORWARD_POLICY="ACCEPT" にしていたため、VPN と無関係な
  #   パケットまで無条件に転送する＝オープンルーター（踏み台/リフレクタ）だった。
  #   平文で届いた「宛先=VPN サブネット」も転送してしまうため、-m policy で
  #   「IPsec で入ってきたか」を必ず確認する。
  apply_ipsec_forward_rules
}

# IPsec 用の転送許可を ufw の before.rules / before6.rules へ冪等に追記する。
# xt_policy が使えるかを実チェーンで検証してから書く（使えない環境で書くと
# iptables-restore が失敗し、ufw ごと有効化できなくなるため）。
apply_ipsec_forward_rules() {
  local ipt fam file subnet in_rule out_rule chain=orenovpn-fwtest
  for fam in v4 v6; do
    if [ "$fam" = v4 ]; then
      ipt=iptables; file=/etc/ufw/before.rules;  subnet="${WG_SUBNET_V4}"
    else
      [ "${WG_ENABLE_IPV6}" = "true" ] || continue
      ipt=ip6tables; file=/etc/ufw/before6.rules; subnet="${WG_SUBNET_V6}"
    fi
    [ -f "$file" ] || continue
    grep -q 'orenovpn-vpn-forward' "$file" && continue

    # xt_policy の可用性テスト（一時チェーンに実際に入れてみる）
    local policy_ok=0
    "$ipt" -N "$chain" >/dev/null 2>&1 || true
    if "$ipt" -A "$chain" -s "$subnet" -m policy --dir in --pol ipsec -j ACCEPT >/dev/null 2>&1; then
      policy_ok=1
    fi
    "$ipt" -F "$chain" >/dev/null 2>&1 || true
    "$ipt" -X "$chain" >/dev/null 2>&1 || true

    if [ "$policy_ok" = 1 ]; then
      in_rule="-A ufw-before-forward -s ${subnet} -m policy --dir in --pol ipsec -m comment --comment orenovpn-vpn-forward -j ACCEPT"
      out_rule="-A ufw-before-forward -d ${subnet} -m policy --dir out --pol ipsec -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment orenovpn-vpn-forward -j ACCEPT"
    else
      # xt_policy 不在時の代替: 送信元/宛先を VPN サブネットに限定する（IPsec 経由か
      # までは確認できないので、rp_filter と併せた弱い防御になる点は doctor が警告する）。
      log "警告: xt_policy が使えないため IPsec 判定なしの転送ルールにフォールバック（make doctor を確認）"
      in_rule="-A ufw-before-forward -s ${subnet} -m comment --comment orenovpn-vpn-forward -j ACCEPT"
      out_rule="-A ufw-before-forward -d ${subnet} -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment orenovpn-vpn-forward -j ACCEPT"
    fi
    sed -i "/^:ufw-before-forward /a ${in_rule}\n${out_rule}" "$file"
    log "IPsec 転送許可を ${file} に追記（VPN サブネット ${subnet} のみ）"
  done
}

case "$VPN_PROTOCOL" in
  wireguard) setup_wireguard ;;
  ikev2)     setup_ikev2 ;;
esac

# -----------------------------------------------------------------------------
# 5. ファイアウォール（ufw）— 最小許可 + プロトコル別ポート
# -----------------------------------------------------------------------------
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
# 転送の既定は DROP。VPN に必要な転送だけを明示的に許可する（WireGuard は wg0.conf の
# PostUp、IKEv2 は apply_ipsec_forward_rules）。ACCEPT にするとオープンルーターになる。
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="DROP"/' /etc/default/ufw
ufw allow "${SSH_PORT}/tcp" comment 'SSH'
case "$VPN_PROTOCOL" in
  wireguard) ufw allow "${WG_PORT}/udp" comment 'WireGuard' ;;
  ikev2)     ufw allow 500/udp comment 'IKEv2'; ufw allow 4500/udp comment 'IKEv2 NAT-T' ;;
esac
# NAT/転送許可は reset 後・enable 前に適用（reset で消えないように）
[ "$VPN_PROTOCOL" = "ikev2" ] && apply_ikev2_nat
ufw --force enable
log "ufw を有効化"
# NAT は enable 前に before.rules へ適用済みのため、ここでの reload は不要
# （reload すると同一 MASQUERADE ルールが二重登録される）。
# ただし WireGuard の転送/NAT は wg0.conf の PostUp が入れており、直前の
# `ufw --force reset` / `enable` で FORWARD が作り直されると消えてしまう。
# 最後に wg-quick を再起動して、限定済みのルールを確実に載せ直す。
if [ "$VPN_PROTOCOL" = "wireguard" ]; then
  if systemctl restart wg-quick@wg0 >/dev/null 2>&1; then
    log "wg-quick を再起動し転送/NAT ルールを再適用"
  else
    log "警告: wg-quick@wg0 の再起動に失敗（make doctor で転送/NAT を確認）"
  fi
fi

# -----------------------------------------------------------------------------
# 6. fail2ban / 自動更新（共通）
# -----------------------------------------------------------------------------
if [ "${ENABLE_FAIL2BAN}" = "true" ] && command -v fail2ban-server >/dev/null 2>&1; then
  cat > /etc/fail2ban/jail.d/orenovpn.local <<EOF
[sshd]
enabled  = true
port     = ${SSH_PORT}
maxretry = 4
findtime = 10m
bantime  = 1h
backend  = systemd
EOF
  systemctl enable --now fail2ban
  systemctl restart fail2ban
  log "fail2ban を設定"
fi

if [ "${ENABLE_AUTO_UPDATES}" = "true" ]; then
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  systemctl enable --now unattended-upgrades 2>/dev/null || true
  log "自動セキュリティ更新を有効化"
fi

# -----------------------------------------------------------------------------
# 7. 初期クライアント作成（vpn-client がプロトコルに応じて振り分け）
# -----------------------------------------------------------------------------
if [ -n "${WG_INITIAL_CLIENTS:-}" ] && command -v vpn-client >/dev/null 2>&1; then
  for client in ${WG_INITIAL_CLIENTS}; do
    # 再実行時に既存クライアントで「エラー」表示にならないよう、出力を捕捉して判定する。
    if out="$(vpn-client add "$client" --quiet 2>&1)"; then
      log "クライアント ${client} を作成"
    elif printf '%s' "$out" | grep -q '既に存在'; then
      log "クライアント ${client} は既存のためスキップ"
    else
      log "クライアント ${client} の作成に失敗: ${out}"
    fi
  done
fi

# -----------------------------------------------------------------------------
# 7.5 アクセス先の記録（宛先IP / ドメイン名）— 既定 OFF のオプトイン
#
#   記録できるものと、できないもの:
#     ○ 宛先 IP・ポート・接続元の VPN 内 IP・時刻（nat PREROUTING の LOG）
#     ○ ドメイン名（自前 unbound の query log。素の DNS(53) は DNAT で強制的に通す）
#     × 完全な URL（TLS で暗号化されているため復号なしには取得不能）
#     △ HTTPS の SNI は取得可能だが常駐解析が必要。将来課題（docs/ALERTING.md 参照）
#     ※ 端末が DoH/DoT（暗号化 DNS）を使う場合、ドメイン名の記録は迂回される。
#
#   置き場所の注意: 宛先 LOG は **nat PREROUTING** に置く。FORWARD だと WireGuard の
#   PostUp が先頭で ACCEPT するため ufw のチェーンへ到達せずログが一切出ない
#   （既存の出口ブロックリスト検知が WireGuard で発火しないのはこれが理由）。
#   nat PREROUTING は FORWARD より前・新規接続の最初のパケットだけを通るため、
#   両プロトコルで「1 接続 1 行」の記録になる。
# -----------------------------------------------------------------------------
configure_access_log() {
  # ルールは systemd の oneshot（check-then-add で冪等）で適用する。
  # before.rules に書くと `ufw reload` が noflush で再適用して二重登録になるため。
  cat >/usr/local/sbin/orenovpn-fwlog-apply <<'EOS'
#!/usr/bin/env bash
# orenovpn-fwlog-apply : アクセス先記録(LOG)と DNS 強制転送(DNAT)を nat PREROUTING へ
#   冪等に適用する（setup.sh が生成）。引数 delete で全削除。
#   設定は /etc/orenovpn/orenovpn.env を読む。
set -euo pipefail
ENV_FILE=/etc/orenovpn/orenovpn.env
# shellcheck disable=SC1090,SC1091
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${ENABLE_ACCESS_LOG:=false}"
: "${ENABLE_DNS_LOGGING:=false}"
: "${ALERT_BLOCKLIST_URL:=}"
: "${WG_ENABLE_IPV6:=false}"
: "${WG_SUBNET_V4:=10.66.66.0/24}"
: "${WG_SUBNET_V6:=fd42:66:66::/64}"
: "${WG_ADDRESS_V4:=10.66.66.1}"
: "${WG_ADDRESS_V6:=fd42:66:66::1}"
MODE="${1:-apply}"

# 出口ブロックリスト検知を入れるか。ipset が無い状態でルールを入れると
# iptables が失敗するため、セットの存在を確認する。
egress_ok() {
  [ -n "$ALERT_BLOCKLIST_URL" ] || return 1
  command -v ipset >/dev/null 2>&1 || return 1
  if ! ipset list -n 2>/dev/null | grep -qx orenovpn_blocklist; then
    echo "[fwlog] ipset(orenovpn_blocklist) が無いため出口検知ルールは入れません" >&2
    return 1
  fi
  return 0
}

# 待受が無いのに DNS を DNAT すると、クライアントの名前解決が全滅する。
# unit が active でも bind に失敗していることがあるため、systemctl ではなく
# 「実際に 53 番が開いているか」で判定する。記録より通信の維持を優先。
dns_dnat_ok() { # $1 = DNAT 先アドレス（v6 は角括弧付き）
  [ "$ENABLE_DNS_LOGGING" = "true" ] || return 1
  if ! command -v ss >/dev/null 2>&1; then
    systemctl is-active --quiet unbound 2>/dev/null && return 0
    echo "[fwlog] ss が無く unbound も非稼働のため DNS 転送は入れません" >&2
    return 1
  fi
  local i listening
  # 起動直後は待受が上がる前に来ることがあるため数回待つ（再起動後に記録が
  # 静かに止まるのを防ぐ）。
  for i in 1 2 3 4 5; do
    # ss は指定プロトコルにより Netid 列の有無が変わる（`ss -uln` は $5 が Peer 側）。
    # 列位置に依存せず ":53" で終わるフィールドを拾う。
    listening="$(ss -uln 2>/dev/null | awk 'NR > 1 {for (j = 1; j <= NF; j++) if ($j ~ /:53$/) print $j}')"
    printf '%s\n' "$listening" | grep -qxF "${1}:53" && return 0
    printf '%s\n' "$listening" | grep -qxE '(0\.0\.0\.0|\*|\[::\]):53' && return 0
    [ "$i" = 5 ] && break
    sleep 1
  done
  echo "[fwlog] ${1}:53 で待受が無いため DNS 転送は入れません（名前解決を優先）" >&2
  return 1
}

ipt_for() { [ "$1" = v6 ] && echo ip6tables || echo iptables; }

# 既存ルールを消す（重複していても全部消えるまで繰り返す）
del_rule() {
  local fam="$1"; shift
  local ipt; ipt="$(ipt_for "$fam")"
  while "$ipt" -t nat -C PREROUTING "$@" >/dev/null 2>&1; do
    "$ipt" -t nat -D PREROUTING "$@" >/dev/null 2>&1 || break
  done
}
add_rule() {
  local fam="$1"; shift
  local ipt; ipt="$(ipt_for "$fam")"
  "$ipt" -t nat -C PREROUTING "$@" >/dev/null 2>&1 || "$ipt" -t nat -A PREROUTING "$@"
}

# 対象ルールの一覧（削除も追加も同じ定義を使うので取り残しが出ない）
for_each_rule() {
  local action="$1" fam sub addr
  for fam in v4 v6; do
    if [ "$fam" = v4 ]; then
      sub="$WG_SUBNET_V4"; addr="$WG_ADDRESS_V4"
    else
      # 削除時は v6 無効でも処理する（v6 を後から無効化した場合の取り残し防止）
      [ "$WG_ENABLE_IPV6" = "true" ] || [ "$action" = del ] || continue
      sub="$WG_SUBNET_V6"; addr="[${WG_ADDRESS_V6}]"
    fi
    # 記録は DNAT より前に置く（DNS も「本来の宛先」で記録されるように）
    # 削除時は設定に関係なく全部消す（無効化したときに取り残さないため）
    if [ "$action" = del ] || [ "$ENABLE_ACCESS_LOG" = "true" ]; then
      "${action}_rule" "$fam" -s "$sub" -j LOG --log-prefix "orenovpn-dst: " --log-level 6
    fi
    if [ "$action" = del ] || dns_dnat_ok "$addr"; then
      "${action}_rule" "$fam" -s "$sub" -p udp --dport 53 -j DNAT --to-destination "${addr}:53"
      "${action}_rule" "$fam" -s "$sub" -p tcp --dport 53 -j DNAT --to-destination "${addr}:53"
    fi
    # 出口ブロックリスト検知（v4 のみ。ipset は family inet）。
    #   必ず「VPN サブネット発」に限定する。向きを限定しないと戻り通信（宛先=VPN内
    #   アドレス）が private 範囲として一致し、大量の誤検知になる。
    #   nat PREROUTING なので新規接続の 1 パケットのみ = 1 接続 1 行。上限も付ける。
    if [ "$fam" = v4 ] && { [ "$action" = del ] || egress_ok; }; then
      "${action}_rule" v4 -s "$sub" -m set --match-set orenovpn_blocklist dst \
        -m limit --limit 30/min --limit-burst 60 \
        -j LOG --log-prefix "orenovpn-egress: " --log-level 4
    fi
  done
}

# apply は「全削除 → 有効なものだけ追加」で設定変更にも追従する
for_each_rule del
[ "$MODE" = delete ] || for_each_rule add
EOS
  chmod 0755 /usr/local/sbin/orenovpn-fwlog-apply

  cat >/etc/systemd/system/orenovpn-fwlog.service <<'EOF'
[Unit]
Description=orenovpn access log / DNS redirect rules
# unbound より後に走らせる（稼働確認できたときだけ DNS を DNAT するため）
After=ufw.service network-online.target unbound.service wg-quick@wg0.service orenovpn-ipset-restore.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/orenovpn-fwlog-apply apply
ExecStop=/usr/local/sbin/orenovpn-fwlog-apply delete

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload

  if [ "${ENABLE_ACCESS_LOG}" = "true" ] || [ "${ENABLE_DNS_LOGGING}" = "true" ]; then
    systemctl enable orenovpn-fwlog.service >/dev/null 2>&1 || true
    /usr/local/sbin/orenovpn-fwlog-apply apply || log "警告: 記録ルールの適用に失敗"
    # journald の保存量と期間に上限を付ける（記録は量が出るため必須）。
    mkdir -p /etc/systemd/journald.conf.d
    cat >/etc/systemd/journald.conf.d/orenovpn-logs.conf <<EOF
# orenovpn が生成。アクセス先/DNS の記録はカーネルログと unbound のログに出るため、
# 使用量と保存期間に上限を付ける（LOG_RETENTION_DAYS=${LOG_RETENTION_DAYS}）。
[Journal]
Storage=persistent
SystemMaxUse=1G
MaxRetentionSec=${LOG_RETENTION_DAYS}day
RateLimitIntervalSec=30s
RateLimitBurst=20000
EOF
    systemctl restart systemd-journald >/dev/null 2>&1 || true
    log "アクセス先の記録を有効化（保存 ${LOG_RETENTION_DAYS} 日 / 上限 1G・make access-log で参照）"
  else
    /usr/local/sbin/orenovpn-fwlog-apply delete >/dev/null 2>&1 || true
    systemctl disable orenovpn-fwlog.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/journald.conf.d/orenovpn-logs.conf
    systemctl restart systemd-journald >/dev/null 2>&1 || true
  fi
}

# 自前 DNS リゾルバ(unbound)で名前解決を記録する。
#   ⚠️ 外部に開くとオープンリゾルバ（増幅攻撃の踏み台）になる。待受は VPN 内アドレスと
#      localhost のみ・access-control でも VPN サブネットだけ許可の二重で塞ぐ。
configure_dns_logging() {
  if [ "${ENABLE_DNS_LOGGING}" != "true" ]; then
    if [ -f /etc/unbound/unbound.conf.d/orenovpn.conf ]; then
      rm -f /etc/unbound/unbound.conf.d/orenovpn.conf
      systemctl disable --now unbound >/dev/null 2>&1 || true
      systemctl disable --now orenovpn-dns-addr.service >/dev/null 2>&1 || true
      log "DNS 記録を無効化（unbound 停止）"
    fi
    return 0
  fi
  command -v unbound >/dev/null 2>&1 || { log "警告: unbound が無いため DNS 記録を構成できません"; return 0; }

  # DNSSEC のルート鍵が無いと unbound は起動できない（Debian の設定が
  # auto-trust-anchor-file を参照するため）。パッケージ導入時に作られなかった場合に備える。
  if [ ! -s /var/lib/unbound/root.key ] && command -v unbound-anchor >/dev/null 2>&1; then
    mkdir -p /var/lib/unbound
    # 鍵を更新すると終了コード 1 を返す仕様のため成否は判定しない
    unbound-anchor -a /var/lib/unbound/root.key >/dev/null 2>&1 || true
    chown -R unbound:unbound /var/lib/unbound 2>/dev/null || true
  fi

  # IKEv2 は wg0 が無く VPN 内アドレスがどこにも付いていないため、lo に付与して
  # クライアントから 10.66.66.1 等で到達できるようにする（WireGuard は wg0 が持つ）。
  if [ "$VPN_PROTOCOL" = "ikev2" ]; then
    local v6add="" v6del=""
    if [ "${WG_ENABLE_IPV6}" = "true" ]; then
      v6add="ExecStart=-/sbin/ip -6 addr add ${WG_ADDRESS_V6}/128 dev lo"
      v6del="ExecStop=-/sbin/ip -6 addr del ${WG_ADDRESS_V6}/128 dev lo"
    fi
    cat >/etc/systemd/system/orenovpn-dns-addr.service <<EOF
[Unit]
Description=orenovpn DNS service address on loopback (IKEv2)
After=network-pre.target
Before=unbound.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-/sbin/ip -4 addr add ${WG_ADDRESS_V4}/32 dev lo
${v6add}
ExecStop=-/sbin/ip -4 addr del ${WG_ADDRESS_V4}/32 dev lo
${v6del}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now orenovpn-dns-addr.service >/dev/null 2>&1 || true
  fi

  local ifaces="  interface: 127.0.0.1
  interface: ${WG_ADDRESS_V4}"
  local acl="  access-control: 0.0.0.0/0 refuse
  access-control: 127.0.0.0/8 allow
  access-control: ${WG_SUBNET_V4} allow"
  local do_ip6="no"
  if [ "${WG_ENABLE_IPV6}" = "true" ]; then
    do_ip6="yes"
    ifaces="${ifaces}
  interface: ::1
  interface: ${WG_ADDRESS_V6}"
    acl="${acl}
  access-control: ::/0 refuse
  access-control: ::1 allow
  access-control: ${WG_SUBNET_V6} allow"
  fi
  mkdir -p /etc/unbound/unbound.conf.d
  cat >/etc/unbound/unbound.conf.d/orenovpn.conf <<EOF
# orenovpn が生成（手動編集は make setup で上書きされます）。
# VPN 内からの問い合わせだけに応答し、名前解決を journald へ記録する。
server:
  verbosity: 1
  # 問い合わせ内容（接続元IP・ドメイン名）を記録する。応答は記録しない。
  log-queries: yes
  log-replies: no
  use-syslog: yes
  # wg0 が上がる前でも VPN 内アドレスにバインドできるようにする
  ip-freebind: yes
  do-ip6: ${do_ip6}
${ifaces}
  # ★ 外部からの問い合わせは拒否（オープンリゾルバ化の防止）
${acl}
  hide-identity: yes
  hide-version: yes
  harden-glue: yes
  harden-dnssec-stripped: yes
  qname-minimisation: yes
  prefetch: yes
  # 512MB プランでも収まる控えめなキャッシュ
  msg-cache-size: 8m
  rrset-cache-size: 16m
  cache-max-ttl: 3600
EOF
  # 上流は wg_dns（利用者が選んだリゾルバ）へ転送する。未設定なら unbound 自身が再帰解決する。
  local d fwd=""
  for d in $(echo "${WG_DNS}" | tr ',' ' '); do
    [ -n "$d" ] && fwd="${fwd}  forward-addr: ${d}"$'\n'
  done
  if [ -n "$fwd" ]; then
    {
      echo 'forward-zone:'
      echo '  name: "."'
      printf '%s' "$fwd"
    } >>/etc/unbound/unbound.conf.d/orenovpn.conf
  fi
  chmod 644 /etc/unbound/unbound.conf.d/orenovpn.conf

  # 設定不備で DNS を壊さないよう、検証に通ったときだけ有効化する（VPN 本体は止めない）。
  if ! unbound-checkconf >/dev/null 2>&1; then
    log "警告: unbound の設定検証に失敗したため DNS 記録を無効化します（unbound-checkconf を確認）"
    rm -f /etc/unbound/unbound.conf.d/orenovpn.conf
    return 0
  fi
  systemctl enable unbound >/dev/null 2>&1 || true
  if systemctl restart unbound >/dev/null 2>&1; then
    log "DNS 記録を有効化（unbound / 待受: ${WG_ADDRESS_V4} と localhost のみ・make dns-log で参照）"
  else
    log "警告: unbound を起動できませんでした（journalctl -u unbound）。DNS 記録は無効のままです"
    rm -f /etc/unbound/unbound.conf.d/orenovpn.conf
    systemctl disable --now unbound >/dev/null 2>&1 || true
    # DNS を死んだリゾルバへ DNAT しないよう、この実行では無効扱いにする
    # （クライアントの名前解決を壊さないことを優先する）。
    ENABLE_DNS_LOGGING=false
    return 0
  fi

  # VPN 内からの 53 番を許可（DNAT 後にローカルへ入るため INPUT の許可が必要）
  ufw allow from "${WG_SUBNET_V4}" to any port 53 proto udp comment 'orenovpn DNS' >/dev/null 2>&1 || true
  ufw allow from "${WG_SUBNET_V4}" to any port 53 proto tcp comment 'orenovpn DNS' >/dev/null 2>&1 || true
  if [ "${WG_ENABLE_IPV6}" = "true" ]; then
    ufw allow from "${WG_SUBNET_V6}" to any port 53 proto udp comment 'orenovpn DNS' >/dev/null 2>&1 || true
    ufw allow from "${WG_SUBNET_V6}" to any port 53 proto tcp comment 'orenovpn DNS' >/dev/null 2>&1 || true
  fi
}

configure_dns_logging
configure_access_log

# ---- 8. 通信監視・警告（watch.sh + systemd timer）--------------------------
# 怪しい通信（SSH 失敗急増・新規接続・トラフィック急増・悪性 IP 通信）を検知して
# メール通知する。詳細は docs/ALERTING.md。監視本体は Makefile が
# /usr/local/sbin/orenovpn-watch に install する。
configure_traffic_alert

# ipset は configure_traffic_alert で作られるため、出口検知ルールを載せるために
# 記録ルールを最後にもう一度適用する（冪等）。
if [ -x /usr/local/sbin/orenovpn-fwlog-apply ]; then
  /usr/local/sbin/orenovpn-fwlog-apply apply || log "警告: 記録ルールの再適用に失敗"
fi

log "セットアップ完了 (${VPN_PROTOCOL})"
