#!/usr/bin/env bash
#
# watch.sh : 怪しい通信を検知して管理者にメールで警告する監視スクリプト。
#   systemd timer（orenovpn-watch.timer）から 5 分毎に実行される想定。冪等・非破壊。
#   検知対象:
#     (1) サーバーへの不審アクセス … SSH 認証失敗の急増（journalctl 集計）
#     (2) 新規 VPN 接続           … 未知ピアのハンドシェイク / 新規 IKE_SA 確立
#     (3) 不審な出口通信          … 既知悪性 IP への通信（setup.sh の FORWARD ログ）
#     (4) トラフィック量の異常    … 1 周期あたり転送量が閾値超過
#   閾値超過・差分検出時に msmtp でメールを送る。同種アラートはクールダウンで抑制。
#   設定は /etc/orenovpn/orenovpn.env（cloud-init 生成）から読む。
#   状態は /var/lib/orenovpn/watch/ に保存し、前回との差分を判定する。
#   設計の詳細は docs/ALERTING.md を参照。
#
set -euo pipefail

ENV_FILE=/etc/orenovpn/orenovpn.env
# shellcheck disable=SC1090,SC1091
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

# ---- 既定値（env 未設定でも安全側で動く）----------------------------------
: "${VPN_PROTOCOL:=wireguard}"
: "${ENABLE_TRAFFIC_ALERT:=false}"
: "${ALERT_EMAIL:=}"
: "${SMTP_USER:=}"
: "${ALERT_SSH_FAIL_THRESHOLD:=20}"
: "${ALERT_TRAFFIC_MBYTES:=1024}"
: "${ALERT_BLOCKLIST_URL:=}"
: "${WG_PORT:=51820}"

WG_IFACE=wg0
STATE_DIR=/var/lib/orenovpn/watch
COOLDOWN_DIR="$STATE_DIR/cooldown"
COOLDOWN_SECONDS=3600
ACTIVE_WINDOW=900
MSMTP_CONF=/etc/msmtprc
HOST_LABEL="$(hostname 2>/dev/null || echo orenovpn)"

logg() { printf '[watch] %s\n' "$*" >&2; }

mkdir -p "$STATE_DIR" "$COOLDOWN_DIR"

# ---- メール送信（msmtp 経由）----------------------------------------------
send_mail() {
  local subject="$1" body="$2" from
  if [ -z "$ALERT_EMAIL" ]; then
    logg "ALERT_EMAIL 未設定のため送信スキップ: $subject"
    return 0
  fi
  if ! command -v msmtp >/dev/null 2>&1; then
    logg "msmtp 不在のため送信スキップ: $subject"
    return 0
  fi
  from="${SMTP_USER:-root@$HOST_LABEL}"
  if {
    printf 'To: %s\n' "$ALERT_EMAIL"
    printf 'From: orenovpn <%s>\n' "$from"
    printf 'Subject: [orenovpn] %s\n' "$subject"
    printf 'Content-Type: text/plain; charset=UTF-8\n'
    printf '\n'
    printf '%s\n' "$body"
    printf '\n-- \norenovpn watch @ %s (%s)\n' "$HOST_LABEL" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  } | msmtp --file="$MSMTP_CONF" "$ALERT_EMAIL"; then
    logg "通知送信: $subject"
  else
    logg "通知送信失敗（msmtp 設定を確認）: $subject"
  fi
}

# ---- クールダウン付きアラート（$1=key $2=subject $3=body）------------------
alert() {
  local key="$1" subject="$2" body="$3" marker now last
  marker="$COOLDOWN_DIR/$key"
  now="$(date +%s)"
  if [ -f "$marker" ]; then
    last="$(cat "$marker" 2>/dev/null || echo 0)"
    if [ "$((now - last))" -lt "$COOLDOWN_SECONDS" ]; then
      logg "クールダウン中のため抑制: $key"
      return 0
    fi
  fi
  send_mail "$subject" "$body"
  printf '%s' "$now" >"$marker"
}

# ---- 監視期間（前回実行時刻から今まで。初回は 5 分前から）------------------
since_arg() {
  local f="$STATE_DIR/last_run"
  if [ -f "$f" ]; then
    cat "$f"
  else
    echo "5 min ago"
  fi
}

# ---- (1) SSH 認証失敗の急増 -------------------------------------------------
check_ssh_fail() {
  local since count
  since="$1"
  command -v journalctl >/dev/null 2>&1 || return 0
  count="$(journalctl -u ssh -u sshd --since "$since" 2>/dev/null \
    | grep -cE 'Failed password|Invalid user|authentication failure' || true)"
  count="${count:-0}"
  if [ "$count" -ge "$ALERT_SSH_FAIL_THRESHOLD" ]; then
    alert "ssh_fail" \
      "SSH 認証失敗の急増を検知（${count} 件）" \
      "監視期間内に SSH 認証失敗が ${count} 件発生しました（閾値 ${ALERT_SSH_FAIL_THRESHOLD} 件）。
ブルートフォースの可能性があります。fail2ban の ban 状況と allowed_ssh_cidr を確認してください。

  期間: ${since} 〜 現在
  確認: sudo fail2ban-client status sshd"
  fi
}

# ---- (2) 新規 VPN 接続（WireGuard）-----------------------------------------
check_new_peers_wg() {
  command -v wg >/dev/null 2>&1 || return 0
  local now cutoff prevfile curfile pk hs newlist
  now="$(date +%s)"
  cutoff="$((now - ACTIVE_WINDOW))"
  prevfile="$STATE_DIR/wg_active_peers"
  curfile="$STATE_DIR/wg_active_peers.cur"
  : >"$curfile"
  while read -r pk hs; do
    [ -n "$pk" ] || continue
    [ "${hs:-0}" -gt "$cutoff" ] && printf '%s\n' "$pk" >>"$curfile"
  done < <(wg show "$WG_IFACE" latest-handshakes 2>/dev/null)

  if [ -f "$prevfile" ]; then
    newlist="$(comm -23 <(sort -u "$curfile") <(sort -u "$prevfile") || true)"
    if [ -n "$newlist" ]; then
      alert "new_peer" \
        "新規 VPN 接続を検知（WireGuard）" \
        "これまで接続の無かったピアがハンドシェイクしました。想定外なら鍵の漏洩を疑ってください。

新規ピア公開鍵:
${newlist}

  確認: sudo wg show ${WG_IFACE}"
    fi
  fi
  mv "$curfile" "$prevfile"
}

# ---- (2) 新規 VPN 接続（IKEv2/IPsec）---------------------------------------
check_new_peers_ikev2() {
  command -v swanctl >/dev/null 2>&1 || return 0
  local prevfile curfile newlist
  prevfile="$STATE_DIR/ikev2_remotes"
  curfile="$STATE_DIR/ikev2_remotes.cur"
  swanctl --list-sas 2>/dev/null \
    | grep -oE 'remote [^ ]+|[0-9]{1,3}(\.[0-9]{1,3}){3}\[[0-9]+\]' \
    | sort -u >"$curfile" || true

  if [ -f "$prevfile" ] && [ -s "$curfile" ]; then
    newlist="$(comm -23 "$curfile" <(sort -u "$prevfile") || true)"
    if [ -n "$newlist" ]; then
      alert "new_peer" \
        "新規 VPN 接続を検知（IKEv2）" \
        "新しいリモートから IKE_SA が確立されました。想定外なら証明書の管理を確認してください。

新規リモート:
${newlist}

  確認: sudo swanctl --list-sas"
    fi
  fi
  if [ -s "$curfile" ]; then
    mv "$curfile" "$prevfile"
  else
    rm -f "$curfile"
  fi
}

# ---- (3) 不審な出口通信（既知悪性 IP。ログのみ・ドロップしない）------------
check_egress() {
  local since count dsts
  since="$1"
  [ -n "$ALERT_BLOCKLIST_URL" ] || return 0
  command -v journalctl >/dev/null 2>&1 || return 0
  count="$(journalctl -k --since "$since" 2>/dev/null | grep -c 'orenovpn-egress:' || true)"
  count="${count:-0}"
  if [ "$count" -gt 0 ]; then
    dsts="$(journalctl -k --since "$since" 2>/dev/null \
      | grep 'orenovpn-egress:' \
      | grep -oE 'DST=[0-9.]+' | sort | uniq -c | sort -rn | head -10 || true)"
    alert "egress" \
      "不審な出口通信を検知（${count} 件）" \
      "VPN クライアントが既知悪性 IP（ブロックリスト該当）へ通信しました。
マルウェア感染や C2 通信の可能性があります。該当クライアントを調査してください。

  件数: ${count}（監視期間内）
  宛先 IP（上位）:
${dsts}"
  fi
}

# ---- (4) トラフィック量の異常 ----------------------------------------------
check_traffic() {
  local prevfile cur prev delta mb
  prevfile="$STATE_DIR/traffic_bytes"
  if [ "$VPN_PROTOCOL" = "wireguard" ] && command -v wg >/dev/null 2>&1; then
    cur="$(wg show "$WG_IFACE" transfer 2>/dev/null \
      | awk '{rx += $2; tx += $3} END {print rx + tx + 0}')"
  elif [ -d /sys/class/net/ipsec0/statistics ]; then
    cur="$(( $(cat /sys/class/net/ipsec0/statistics/rx_bytes 2>/dev/null || echo 0) \
            + $(cat /sys/class/net/ipsec0/statistics/tx_bytes 2>/dev/null || echo 0) ))"
  else
    return 0
  fi
  cur="${cur:-0}"
  if [ -f "$prevfile" ]; then
    prev="$(cat "$prevfile" 2>/dev/null || echo 0)"
    if [ "$cur" -ge "$prev" ]; then
      delta="$((cur - prev))"
      mb="$((delta / 1048576))"
      if [ "$mb" -ge "$ALERT_TRAFFIC_MBYTES" ]; then
        alert "traffic" \
          "トラフィック量の急増を検知（${mb} MB）" \
          "直近の監視周期で VPN 転送量が ${mb} MB に達しました（閾値 ${ALERT_TRAFFIC_MBYTES} MB）。
大量ダウンロード・データ持ち出し・踏み台化などの可能性があります。"
      fi
    fi
  fi
  printf '%s' "$cur" >"$prevfile"
}

# ---- テスト通知（make alerts-test / 手動確認用）----------------------------
if [ "${1:-}" = "test" ]; then
  send_mail "テスト通知" "これは orenovpn watch のテスト通知です。このメールが届けば SMTP 設定は正常です。"
  exit 0
fi

# ---- メイン ----------------------------------------------------------------
if [ "$ENABLE_TRAFFIC_ALERT" != "true" ]; then
  logg "ENABLE_TRAFFIC_ALERT=false のため監視をスキップ"
  exit 0
fi

SINCE="$(since_arg)"

check_ssh_fail "$SINCE" || logg "check_ssh_fail 失敗"
if [ "$VPN_PROTOCOL" = "ikev2" ]; then
  check_new_peers_ikev2 || logg "check_new_peers_ikev2 失敗"
else
  check_new_peers_wg || logg "check_new_peers_wg 失敗"
fi
check_egress "$SINCE" || logg "check_egress 失敗"
check_traffic || logg "check_traffic 失敗"

date '+%Y-%m-%d %H:%M:%S' >"$STATE_DIR/last_run"
logg "監視完了（protocol=${VPN_PROTOCOL}）"
