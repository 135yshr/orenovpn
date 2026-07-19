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
  local POSTUP="iptables -I FORWARD 1 -i %i -j ACCEPT; iptables -I FORWARD 1 -o %i -j ACCEPT; iptables -t nat -I POSTROUTING 1 -o ${WAN_IF} -j MASQUERADE"
  local POSTDOWN="iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WAN_IF} -j MASQUERADE"
  if [ "${WG_ENABLE_IPV6}" = "true" ]; then
    local V6_PREFIX="${WG_SUBNET_V6##*/}"
    ADDRESS_LINE="${ADDRESS_LINE}, ${WG_ADDRESS_V6}/${V6_PREFIX}"
    POSTUP="${POSTUP}; ip6tables -I FORWARD 1 -i %i -j ACCEPT; ip6tables -I FORWARD 1 -o %i -j ACCEPT; ip6tables -t nat -I POSTROUTING 1 -o ${WAN_IF} -j MASQUERADE"
    POSTDOWN="${POSTDOWN}; ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -D FORWARD -o %i -j ACCEPT; ip6tables -t nat -D POSTROUTING -o ${WAN_IF} -j MASQUERADE"
  fi
  if [ ! -f "$WG_CONF" ]; then
    cat > "$WG_CONF" <<EOF
# orenovpn WireGuard サーバー設定（クライアントは 'vpn-client' で管理）
[Interface]
Address = ${ADDRESS_LINE}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
PostUp = ${POSTUP}
PostDown = ${POSTDOWN}
EOF
    chmod 600 "$WG_CONF"
    log "wg0.conf を生成"
  fi
  systemctl enable --now "wg-quick@${WG_IF}"
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

  # --- swanctl 接続定義（IKEv2 / 証明書認証 / ロードウォリア）
  local DNS_SW; DNS_SW="$(echo "${WG_DNS}" | sed 's/,/, /g')"
  # IPv6 リーク対策: v6 有効時のみ ::/0 を提示し、v6 内部アドレスも配布する。
  # （v6 を提示するだけで配布しないと、端末のネイティブ v6 がトンネル外へ漏れる。
  #   逆に v6 無効時は ::/0 を一切提示しない＝端末に v6 経路を作らせない。）
  local LOCAL_TS="0.0.0.0/0" POOL_REF="orenovpn_pool" POOL6_BLOCK=""
  if [ "${WG_ENABLE_IPV6}" = "true" ]; then
    LOCAL_TS="0.0.0.0/0, ::/0"
    POOL_REF="orenovpn_pool, orenovpn_pool6"
    # v4/v6 は別プールに分ける（swanctl の pool.addrs は 1 プール 1 アドレス族が確実。
    #  混在指定だと片方しか読み込まれず "no virtual IP found for %any6" になる）。
    POOL6_BLOCK="  orenovpn_pool6 {
    addrs = ${WG_SUBNET_V6}
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
    addrs = ${WG_SUBNET_V4}
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
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
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
    vpn-client add "$client" --quiet || log "クライアント ${client} の作成に失敗"
  done
fi

log "セットアップ完了 (${VPN_PROTOCOL})"
