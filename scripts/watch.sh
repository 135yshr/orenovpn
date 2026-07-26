#!/usr/bin/env bash
#
# watch.sh : 怪しい通信を検知して管理者にメールで警告する監視スクリプト。
#   systemd timer（orenovpn-watch.timer）から 5 分毎に実行される想定。冪等・非破壊。
#   検知対象:
#     (1) サーバーへの不審アクセス … SSH 認証失敗の急増（journalctl 集計）
#     (2) 新規 VPN 接続           … 未知ピアのハンドシェイク / 新規 IKE_SA 確立
#     (3) 不審な出口通信          … 既知悪性 IP への通信（setup.sh の FORWARD ログ）
#     (4) トラフィック量の異常    … 1 周期あたり転送量が閾値超過
#     (5) 資格情報の複製          … 同じ鍵/証明書IDが短時間に複数の接続元 IP から使用
#         ※ (2) は「未知の鍵」しか見ないため、設定ファイルを複製されて正規の鍵で
#           接続された場合は検知できない。(5) がその穴を埋める。
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
: "${SMTP_MODE:=relay}"
: "${MAIL_FROM:=}"
: "${ALERT_SSH_FAIL_THRESHOLD:=20}"
: "${ALERT_TRAFFIC_MBYTES:=1024}"
: "${ALERT_BLOCKLIST_URL:=}"
: "${WG_PORT:=51820}"
# 同一の鍵/証明書IDが 1 時間内にこの数以上の接続元 IP から使われたら警告する。
# 回線切替の多い端末で誤検知が続く場合は orenovpn.env に値を書いて上げる。
: "${ALERT_PEER_IP_THRESHOLD:=3}"

WG_IFACE=wg0
STATE_DIR=/var/lib/orenovpn/watch
COOLDOWN_DIR="$STATE_DIR/cooldown"
COOLDOWN_SECONDS=3600
ACTIVE_WINDOW=900
PEER_IP_WINDOW=3600
TAB="$(printf '\t')"
MSMTP_CONF=/etc/msmtprc
HOST_LABEL="$(hostname 2>/dev/null || echo orenovpn)"

logg() { printf '[watch] %s\n' "$*" >&2; }

mkdir -p "$STATE_DIR" "$COOLDOWN_DIR"

# ---- メール送信（msmtp 経由）----------------------------------------------
send_mail() {
  local subject="$1" body="$2" from sm
  if [ -z "$ALERT_EMAIL" ]; then
    logg "ALERT_EMAIL 未設定のため送信スキップ: $subject"
    return 0
  fi
  if [ "$SMTP_MODE" = "local" ]; then
    sm="$(command -v sendmail 2>/dev/null || true)"
    if [ -z "$sm" ] && [ -x /usr/sbin/sendmail ]; then sm=/usr/sbin/sendmail; fi
    if [ -z "$sm" ]; then
      logg "sendmail(dma) 不在のため送信スキップ: $subject"
      return 0
    fi
    if {
      printf 'To: %s\n' "$ALERT_EMAIL"
      printf 'From: %s\n' "${MAIL_FROM:-$ALERT_EMAIL}"
      printf 'Subject: [orenovpn] %s\n' "$subject"
      printf 'Content-Type: text/plain; charset=UTF-8\n'
      printf '\n'
      printf '%s\n' "$body"
    } | "$sm" -t; then
      logg "通知送信(local/dma): $subject"
    else
      logg "通知送信失敗(local/dma): $subject"
    fi
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
  local prevfile curfile newlist sas
  prevfile="$STATE_DIR/ikev2_remotes"
  curfile="$STATE_DIR/ikev2_remotes.cur"
  # 「swanctl が失敗した」と「接続が 0 件」を区別する。失敗時は状態を触らない
  # （空で上書きすると次回に全接続を新規扱いして誤検知する）。
  if ! sas="$(swanctl --list-sas 2>/dev/null)"; then
    logg "swanctl --list-sas に失敗（前回の状態を維持）"
    return 0
  fi
  # 接続が 0 件でも空ファイルとして必ず記録する。ここで空を書かないと prevfile が
  # 作られず、「接続ゼロ → 初回接続」の遷移が永久に検知できない（初回接続で
  # メールが来ない原因だった）。
  : >"$curfile"
  printf '%s\n' "$sas" \
    | grep -oE 'remote [^ ]+|[0-9]{1,3}(\.[0-9]{1,3}){3}\[[0-9]+\]' \
    | sort -u >>"$curfile" || true

  if [ -f "$prevfile" ]; then
    newlist="$(comm -23 "$curfile" <(sort -u "$prevfile") || true)"
    if [ -n "$newlist" ]; then
      alert "new_peer" \
        "新規 VPN 接続を検知（IKEv2）" \
        "新しいリモートから IKE_SA が確立されました。想定外なら証明書の管理を確認してください。

新規リモート:
${newlist}

  確認: sudo swanctl --list-sas
  ※ 同じ端末が同じ接続元 IP から再接続した場合は（既知のため）通知しません。"
    fi
  fi
  mv "$curfile" "$prevfile"
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
  elif [ "$VPN_PROTOCOL" = "ikev2" ] && command -v swanctl >/dev/null 2>&1; then
    # policy ベースの IPsec には ipsec0 のようなインターフェイスが無く、
    # /sys/class/net からは転送量が取れない（この分岐が無いと IKEv2 では
    # トラフィック監視が一切動かなかった）。CHILD_SA の転送量を合算する。
    # 「<数値> bytes,」の直前の数値を拾う。鍵の再生成でカウンタが 0 に戻るため
    # 減少時は下の cur >= prev 判定で差分を取らない。
    cur="$(swanctl --list-sas 2>/dev/null \
      | awk '{for (i = 1; i < NF; i++) if ($(i + 1) ~ /^bytes/) s += $i} END {print s + 0}')"
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

# ---- (5) 資格情報の複製検知 -------------------------------------------------
# 現在アクティブな「識別子 <TAB> 接続元IP」を列挙する。
#   WireGuard … ピア公開鍵（設定ファイルを複製されても鍵は同じ）
#   IKEv2     … クライアント証明書の ID（プロファイルを複製されても ID は同じ）
collect_active_identities() {
  if [ "$VPN_PROTOCOL" = "ikev2" ]; then
    command -v swanctl >/dev/null 2>&1 || return 0
    swanctl --list-sas 2>/dev/null \
      | grep -oE "remote '[^']+' @ [0-9a-fA-F.:]+" \
      | sed -E "s/^remote '([^']+)' @ (.+)$/\1${TAB}\2/"
    return 0
  fi
  command -v wg >/dev/null 2>&1 || return 0
  local now cutoff pk ep hs ip
  now="$(date +%s)"
  cutoff="$((now - ACTIVE_WINDOW))"
  # wg show dump: 1行目はインターフェイス。ピア行は pubkey/psk/endpoint/allowed/handshake...
  while read -r pk ep hs; do
    [ -n "${pk:-}" ] || continue
    [ "${ep:-(none)}" != "(none)" ] || continue
    [ "${hs:-0}" -gt "$cutoff" ] 2>/dev/null || continue
    ip="${ep%:*}"; ip="${ip#[}"; ip="${ip%]}"
    printf '%s%s%s\n' "$pk" "$TAB" "$ip"
  done < <(wg show "$WG_IFACE" dump 2>/dev/null | tail -n +2 | awk -F'\t' '{print $1, $3, $5}')
}

check_identity_ip_reuse() {
  local now prune f tmp
  now="$(date +%s)"
  prune="$((now - PEER_IP_WINDOW))"
  f="$STATE_DIR/identity_ips"
  tmp="${f}.cur"
  : >"$tmp"
  # 期限内の履歴を引き継ぐ
  [ -f "$f" ] && awk -F'\t' -v p="$prune" '$1 ~ /^[0-9]+$/ && $1 + 0 >= p + 0' "$f" >>"$tmp"
  while IFS="$TAB" read -r id ip; do
    [ -n "${id:-}" ] && [ -n "${ip:-}" ] || continue
    printf '%s%s%s%s%s\n' "$now" "$TAB" "$id" "$TAB" "$ip" >>"$tmp"
  done < <(collect_active_identities)
  # (識別子, IP) ごとに最新時刻だけ残して履歴を更新
  awk -F'\t' '{k = $2 FS $3; if ($1 + 0 > t[k] + 0) t[k] = $1} END {for (k in t) print t[k] FS k}' \
    "$tmp" | sort >"$f"
  rm -f "$tmp"

  # 識別子ごとに通知する。クールダウンのキーを 1 つに共有すると、別の識別子が
  # 新たに複製されても先のアラートのクールダウン中は最大 1 時間抑制されてしまう
  # （独立した侵害を取りこぼす）。識別子はファイル名に使えない文字を含みうるため
  # ハッシュの先頭をキーにする。
  local id count ips key
  while IFS=$'\t' read -r id count ips; do
    [ -n "${id:-}" ] || continue
    key="identity_reuse_$(printf '%s' "$id" | sha256sum | cut -c1-12)"
    alert "$key" \
      "同一の VPN 資格情報が複数の接続元から使用（複製の疑い）: ${id}" \
      "鍵/証明書「${id}」が直近 1 時間で ${count} 個の接続元 IP から使われました
（閾値 ${ALERT_PEER_IP_THRESHOLD}）。設定ファイル/プロファイルが複製された可能性があります
（正規の鍵で接続されるため「新規ピア」としては検知されません）。

  接続元:${ips}

  確認: sudo wg show ${WG_IFACE} / sudo swanctl --list-sas
  対処: 該当クライアントを作り直す（make remove NAME=x && make client NAME=x）
        IKEv2 は失効(CRL)が有効でないと止められません（make doctor で確認）
  ※ 回線切替の多い端末では正常でも出ます。続く場合は orenovpn.env の
     ALERT_PEER_IP_THRESHOLD を上げてください（現在 ${ALERT_PEER_IP_THRESHOLD}）。"
  done < <(awk -F'\t' -v th="$ALERT_PEER_IP_THRESHOLD" '
    {c[$2]++; s[$2] = s[$2] " " $3}
    END {for (i in c) if (c[i] + 0 >= th + 0) printf "%s\t%d\t%s\n", i, c[i], s[i]}' "$f")
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
check_identity_ip_reuse || logg "check_identity_ip_reuse 失敗"

date '+%Y-%m-%d %H:%M:%S' >"$STATE_DIR/last_run"
logg "監視完了（protocol=${VPN_PROTOCOL}）"
