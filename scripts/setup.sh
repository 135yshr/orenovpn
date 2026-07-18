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
  cat > /etc/swanctl/swanctl.conf <<EOF
connections {
  orenovpn {
    version = 2
    proposals = aes256-sha256-modp2048,aes256gcm16-prfsha384-ecp384
    rekey_time = 0
    pools = orenovpn_pool
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
        local_ts = 0.0.0.0/0, ::/0
        esp_proposals = aes256-sha256,aes256gcm16
        rekey_time = 0
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
}
EOF
  chmod 600 /etc/swanctl/swanctl.conf

  # --- NAT（VPN サブネット → WAN）。ufw の before.rules に冪等に追記
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
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

  # swanctl ベースのサービスを起動（Debian のパッケージ差異に備えて候補を順に試行）
  local started=""
  for svc in strongswan.service strongswan-swanctl.service strongswan; do
    if systemctl enable --now "$svc" >/dev/null 2>&1; then started="$svc"; break; fi
  done
  [ -n "$started" ] || log "警告: strongSwan サービスを自動起動できませんでした（手動確認が必要）"
  systemctl restart "${started:-strongswan}" 2>/dev/null || true
  swanctl --load-all 2>&1 || log "警告: swanctl --load-all に失敗（サービス状態を確認してください）"
  log "IKEv2/IPsec (strongSwan) 構成完了 サービス=${started:-unknown}"
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
ufw --force enable
log "ufw を有効化"

# NAT を反映するため ufw をリロード（ikev2 の before.rules 反映）
[ "$VPN_PROTOCOL" = "ikev2" ] && ufw reload >/dev/null 2>&1 || true

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
