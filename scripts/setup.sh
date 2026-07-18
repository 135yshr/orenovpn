#!/usr/bin/env bash
#
# orenovpn サーバー構成スクリプト（フェーズ2）
#   `make setup` が SSH 経由でサーバーに転送し sudo 実行する。
#   パッケージ導入・WireGuard 構成・ファイアウォール・堅牢化を行う。
#   何度でも再実行可能（冪等）。出力は端末に表示され、デバッグが容易。
#
# 設定値は /etc/orenovpn/orenovpn.env（cloud-init が生成）から読み込む。
#
set -euo pipefail

ENV_FILE=/etc/orenovpn/orenovpn.env
# shellcheck disable=SC1090
source "$ENV_FILE"

log() { echo "[orenovpn] $*"; }

WG_IF=wg0
WG_CONF="/etc/wireguard/${WG_IF}.conf"

# -----------------------------------------------------------------------------
# 0. 必要パッケージの導入（cloud-init では入れず、ここで導入して進捗を可視化）
# -----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
log "パッケージ情報を更新中..."
apt-get update -qq
PKGS="wireguard wireguard-tools iptables ufw qrencode curl ca-certificates"
[ "${ENABLE_FAIL2BAN}" = "true" ] && PKGS="$PKGS fail2ban"
[ "${ENABLE_AUTO_UPDATES}" = "true" ] && PKGS="$PKGS unattended-upgrades apt-listchanges"
log "パッケージを導入中: ${PKGS}"
# shellcheck disable=SC2086
apt-get install -y -qq $PKGS
log "パッケージ導入完了"

# -----------------------------------------------------------------------------
# 1. WAN インターフェイスとパブリック IP を自動検出
#    ConoHa は eth0 に直接グローバル IP を割り当てる（NAT なし）。
# -----------------------------------------------------------------------------
WG_WAN_IFACE="$(ip -4 route show default | awk '{print $5; exit}')"
WG_ENDPOINT_IP="$(ip -4 addr show "$WG_WAN_IFACE" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
log "WAN=${WG_WAN_IFACE} endpoint=${WG_ENDPOINT_IP}"

# wg-client からも参照できるよう env ファイルへ追記（重複追記を防ぐ）
if ! grep -q '^WG_WAN_IFACE=' "$ENV_FILE"; then
  {
    echo "WG_WAN_IFACE=\"${WG_WAN_IFACE}\""
    echo "WG_ENDPOINT_IP=\"${WG_ENDPOINT_IP}\""
  } >> "$ENV_FILE"
fi

# -----------------------------------------------------------------------------
# 2. WireGuard サーバー鍵の生成
# -----------------------------------------------------------------------------
umask 077
mkdir -p /etc/wireguard
if [ ! -f /etc/wireguard/server_private.key ]; then
  wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
  log "サーバー鍵を生成しました"
fi
SERVER_PRIV="$(cat /etc/wireguard/server_private.key)"

# -----------------------------------------------------------------------------
# 3. wg0.conf の生成（NAT/転送は PostUp/PostDown で設定）
# -----------------------------------------------------------------------------
V4_PREFIX="${WG_SUBNET_V4##*/}"
ADDRESS_LINE="${WG_ADDRESS_V4}/${V4_PREFIX}"

POSTUP="iptables -I FORWARD 1 -i %i -j ACCEPT; iptables -I FORWARD 1 -o %i -j ACCEPT; iptables -t nat -I POSTROUTING 1 -o ${WG_WAN_IFACE} -j MASQUERADE"
POSTDOWN="iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WG_WAN_IFACE} -j MASQUERADE"

if [ "${WG_ENABLE_IPV6}" = "true" ]; then
  V6_PREFIX="${WG_SUBNET_V6##*/}"
  ADDRESS_LINE="${ADDRESS_LINE}, ${WG_ADDRESS_V6}/${V6_PREFIX}"
  POSTUP="${POSTUP}; ip6tables -I FORWARD 1 -i %i -j ACCEPT; ip6tables -I FORWARD 1 -o %i -j ACCEPT; ip6tables -t nat -I POSTROUTING 1 -o ${WG_WAN_IFACE} -j MASQUERADE"
  POSTDOWN="${POSTDOWN}; ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -D FORWARD -o %i -j ACCEPT; ip6tables -t nat -D POSTROUTING -o ${WG_WAN_IFACE} -j MASQUERADE"
fi

if [ ! -f "$WG_CONF" ]; then
  cat > "$WG_CONF" <<EOF
# orenovpn WireGuard サーバー設定
# クライアントの追加/削除は 'wg-client' コマンドで行うこと（手動編集は最小限に）。
[Interface]
Address = ${ADDRESS_LINE}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
PostUp = ${POSTUP}
PostDown = ${POSTDOWN}
EOF
  chmod 600 "$WG_CONF"
  log "${WG_CONF} を生成しました"
fi

# -----------------------------------------------------------------------------
# 4. カーネルパラメータ（IP 転送 + 堅牢化）
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
# 5. ファイアウォール（ufw）— 最小許可
# -----------------------------------------------------------------------------
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment 'SSH'
ufw allow "${WG_PORT}/udp" comment 'WireGuard'
ufw --force enable
log "ufw を有効化しました (SSH:${SSH_PORT}/tcp, WG:${WG_PORT}/udp)"

# -----------------------------------------------------------------------------
# 6. fail2ban（SSH ブルートフォース対策）
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
  log "fail2ban を設定しました"
fi

# -----------------------------------------------------------------------------
# 7. 自動セキュリティ更新（unattended-upgrades）
# -----------------------------------------------------------------------------
if [ "${ENABLE_AUTO_UPDATES}" = "true" ]; then
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  systemctl enable --now unattended-upgrades 2>/dev/null || true
  log "自動セキュリティ更新を有効化しました"
fi

# -----------------------------------------------------------------------------
# 8. WireGuard を起動
# -----------------------------------------------------------------------------
systemctl enable --now "wg-quick@${WG_IF}"
log "WireGuard を起動しました"

# -----------------------------------------------------------------------------
# 9. 初期クライアントの作成
# -----------------------------------------------------------------------------
if [ -n "${WG_INITIAL_CLIENTS:-}" ]; then
  for client in ${WG_INITIAL_CLIENTS}; do
    /usr/local/sbin/wg-client add "$client" --quiet || log "クライアント ${client} の作成に失敗"
  done
fi

log "セットアップ完了"
