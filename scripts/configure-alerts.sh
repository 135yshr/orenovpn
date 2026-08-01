#!/usr/bin/env bash
#
# configure-alerts.sh : 既存サーバーにアラート設定を反映する（make configure-alerts）。
#   クライアント側で対話入力し、SSH でサーバーの /etc/orenovpn/orenovpn.env を
#   更新後、setup.sh の alerts モードで監視を冪等に再構成する。
#   SMTP パスワードは Terraform state に残らず、値はデータとしてサーバーへ渡す
#   （シェルへ展開しないためインジェクションも回避。特殊文字はエスケープ）。
#   make 経由で ORENOVPN_SSH に SSH コマンドを受け取って実行される。
#
set -euo pipefail

: "${ORENOVPN_SSH:?make configure-alerts 経由で実行してください（ORENOVPN_SSH 未設定）}"

prompt() { local v; printf '%s' "$1" >&2; read -r v; printf '%s' "$v"; }

printf '送信方式を選択してください:\n' >&2
printf '  1) 外部 SMTP リレー（Gmail 等・ユーザー名/パスワード認証）\n' >&2
printf '  2) 自前 SMTP サーバー（認証なし、または任意で認証）\n' >&2
printf '  3) VPN 上のローカル MTA（外部SMTP不要・dma が宛先へ直接配送・中継なし/localhost のみ）\n' >&2
MODE="$(prompt '番号 [1]: ')"; MODE="${MODE:-1}"

AE="$(prompt 'ALERT_EMAIL (通知先メール): ')"

if [ "$MODE" = "3" ]; then
  # ローカル MTA(dma): 外部SMTP不要・待受ソケット無し＝中継なし・localhost のみ。宛先MXへ直接配送。
  SMTP_MODE=local
  MF="$(prompt "MAIL_FROM (差出人・任意) [${AE}]: ")"; MF="${MF:-$AE}"
  SMTPHOST=""
  SP=""
  AUTH=off
  SU=""
  PW=""
  printf 'ローカル MTA(dma) で直接配送します（外部SMTP不要・待受なし＝中継なし・localhost のみ）。\n' >&2
  printf '到達性のため、DNS 逆引き(PTR) と SPF（可能なら DKIM）の設定を推奨します（ConoHa CP で PTR を設定）。\n' >&2
else
  SMTP_MODE=relay
  MF=""
  SMTPHOST="$(prompt 'SMTP_HOST: ')"
  SP="$(prompt 'SMTP_PORT [587]: ')"; SP="${SP:-587}"
  if [ "$MODE" = "2" ]; then
    UA="$(prompt 'この SMTP は認証が必要ですか? [y/N]: ')"
    case "$UA" in
      [Yy]*) AUTH=on ;;
      *)     AUTH=off ;;
    esac
  else
    AUTH=on
  fi
  if [ "$AUTH" = "on" ]; then
    SU="$(prompt "SMTP_USER [${AE}]: ")"; SU="${SU:-$AE}"
    printf 'SMTP_PASSWORD: ' >&2
    stty -echo 2>/dev/null || true
    IFS= read -r PW
    stty echo 2>/dev/null || true
    printf '\n' >&2
  else
    SU=""
    PW=""
    printf '認証なしで設定します（自前 SMTP は STARTTLS 既定。平文のみの場合は後で /etc/msmtprc を調整）。\n' >&2
  fi
fi
# SSH ログイン成功の通知。鍵が漏れた場合の侵入は認証失敗を伴わないため、
# 「失敗の急増」では気付けない。既定 ON。
SL="$(prompt 'SSH ログイン成功をメールで通知しますか? [Y/n]: ')"
case "$SL" in
  [Nn]*) SSHLOGIN=false ;;
  *)     SSHLOGIN=true ;;
esac
SLIGN=""
if [ "$SSHLOGIN" = "true" ]; then
  SLIGN="$(prompt '通知から除外する接続元 IP（空白区切り・任意）: ')"
  printf '自分の作業（make setup 等）のログインでも通知が届きます。\n' >&2
fi

# クライアント（プロファイル）の作成/削除の通知。プロファイルは資格情報そのもので、
# root を取られると新しい鍵を発行されうる。作成イベントは居座り用の鍵に気付く手段。既定 ON。
CC="$(prompt 'VPN クライアントの作成/削除をメールで通知しますか? [Y/n]: ')"
case "$CC" in
  [Nn]*) CLICHG=false ;;
  *)     CLICHG=true ;;
esac

BL="$(prompt 'ALERT_BLOCKLIST_URL (任意・空でスキップ): ')"

# env ファイル（bash が source する）へ安全に書けるよう \ " ` $ をエスケープ
esc() { printf '%s' "$1" | sed 's/[\\"`$]/\\&/g'; }

fragment="$(
  printf 'ENABLE_TRAFFIC_ALERT="true"\n'
  printf 'SMTP_MODE="%s"\n' "$(esc "$SMTP_MODE")"
  printf 'ALERT_EMAIL="%s"\n' "$(esc "$AE")"
  printf 'MAIL_FROM="%s"\n' "$(esc "$MF")"
  printf 'SMTP_HOST="%s"\n' "$(esc "$SMTPHOST")"
  printf 'SMTP_PORT="%s"\n' "$(esc "$SP")"
  printf 'SMTP_AUTH="%s"\n' "$(esc "$AUTH")"
  printf 'SMTP_USER="%s"\n' "$(esc "$SU")"
  printf 'SMTP_PASSWORD="%s"\n' "$(esc "$PW")"
  printf 'ENABLE_SSH_LOGIN_ALERT="%s"\n' "$SSHLOGIN"
  printf 'ENABLE_CLIENT_CHANGE_ALERT="%s"\n' "$CLICHG"
  printf 'ALERT_SSH_LOGIN_IGNORE_IPS="%s"\n' "$(esc "$SLIGN")"
  printf 'ALERT_BLOCKLIST_URL="%s"\n' "$(esc "$BL")"
)"

# サーバー側で env を安全に更新する（資格情報を予測可能な /tmp に置かない）。
#   - リモートスクリプトはユーザー入力を含まない固定文字列 → シェルインジェクション不可
#   - パスワードを含む fragment は stdin のデータとして渡す（コマンド列に展開しない）
#   - 一時ファイルは root 所有・umask 077 の mktemp（予測不能・0600・レース回避）
REMOTE_MERGE='
set -e
umask 077
ENVF=/etc/orenovpn/orenovpn.env
new="$(mktemp)"
frag="$(mktemp)"
cat > "$frag"
grep -vE "^(ENABLE_TRAFFIC_ALERT|SMTP_MODE|ALERT_EMAIL|MAIL_FROM|SMTP_HOST|SMTP_PORT|SMTP_AUTH|SMTP_USER|SMTP_PASSWORD|ENABLE_SSH_LOGIN_ALERT|ENABLE_CLIENT_CHANGE_ALERT|ALERT_SSH_LOGIN_IGNORE_IPS|ALERT_BLOCKLIST_URL)=" "$ENVF" > "$new" || true
cat "$frag" >> "$new"
install -m 600 -o root -g root "$new" "$ENVF"
rm -f "$new" "$frag"
# umask を戻してから setup.sh を呼ぶ（077 のままだと setup.sh が作る
# /etc/dma 等が 0700 になり、dma が設定を読めず送信できなくなる）
umask 022
/usr/local/sbin/setup.sh alerts
'
# shellcheck disable=SC2086
printf '%s\n' "$fragment" | $ORENOVPN_SSH "sudo bash -c '$REMOTE_MERGE'"

printf '\n完了しました。`make alerts-test` で送信確認できます。\n' >&2
