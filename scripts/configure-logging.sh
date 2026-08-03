#!/usr/bin/env bash
#
# configure-logging.sh : 既存サーバーのアクセス先記録を ON/OFF する（make configure-logging）。
#   tfvars を変えても既存 VPS の orenovpn.env は更新されない（cloud-init は初回のみ）ため、
#   env を SSH で書き換えてから setup.sh を再実行する方式をとる。
#   make 経由で ORENOVPN_SSH に SSH コマンドを受け取って実行される。
#
#   環境変数: ACCESS_LOG=on|off  DNS_LOG=on|off  DAYS=<保存日数>
#   DAYS を省略した場合は保存期間を変更しない（既存の値をそのまま残す）。
#
set -euo pipefail

: "${ORENOVPN_SSH:?make configure-logging 経由で実行してください（ORENOVPN_SSH 未設定）}"

norm() { # on|true|yes → true / それ以外は false（不正値はエラー）
  case "${1:-off}" in
    on|true|yes|1)   echo true ;;
    off|false|no|0|"") echo false ;;
    *) echo "エラー: '$1' は on / off で指定してください" >&2; exit 1 ;;
  esac
}

AL="$(norm "${ACCESS_LOG:-off}")"
DL="$(norm "${DNS_LOG:-off}")"

# DAYS を省略したときは保存期間を変更しない。既定値で必ず上書きしていた頃は、
# ON/OFF を切り替えるだけのつもりでも保存期間が既定へ戻っていた（30 日運用の
# サーバーが 14 日に戻り、それより古い記録を失いかけた）。
DAYS="${DAYS:-}"
if [ -n "$DAYS" ]; then
  case "$DAYS" in *[!0-9]*) echo "エラー: DAYS は整数で指定してください" >&2; exit 1 ;; esac
  [ "$DAYS" -ge 1 ] || { echo "エラー: DAYS は 1 以上で指定してください" >&2; exit 1; }
  DAYS_MSG="${DAYS}日"
else
  DAYS_MSG="変更しない（現在の設定を維持）"
fi

echo "設定を反映します: 宛先IP記録=${AL} / DNS記録=${DL} / 保存=${DAYS_MSG}" >&2
echo "※ サーバー上で setup.sh を再実行します（冪等）。ufw と VPN が一瞬再適用されるため、" >&2
echo "   接続中の端末は再接続が必要になる場合があります。" >&2
if [ "$DL" = true ]; then
  echo "※ DNS 記録はサーバー上に unbound を立て、VPN からの 53 番を強制的にそこへ通します。" >&2
  echo "   端末が DoH/DoT（暗号化DNS）を使う場合は記録されません（宛先IP は残ります）。" >&2
fi

# 値は検証済みの固定語彙のみ。リモート側スクリプトはユーザー入力を含まない固定文字列とし、
# 設定断片は stdin のデータとして渡す（コマンド列に展開しない）。
fragment="$(
  printf 'ENABLE_ACCESS_LOG="%s"\n' "$AL"
  printf 'ENABLE_DNS_LOGGING="%s"\n' "$DL"
  [ -n "$DAYS" ] && printf 'LOG_RETENTION_DAYS="%s"\n' "$DAYS"
  true
)"

REMOTE_MERGE='
set -e
umask 077
ENVF=/etc/orenovpn/orenovpn.env
new="$(mktemp)"
frag="$(mktemp)"
cat > "$frag"
# 断片に含まれるキーだけを既存から取り除く（含まれないキーは現状のまま残す）。
# 固定の一覧で消していた頃は、渡していない LOG_RETENTION_DAYS まで消えたうえで
# 既定値が書き戻され、保存期間が黙って変わっていた。
cp "$ENVF" "$new"
sed -n "s/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p" "$frag" | while read -r k; do
  grep -v "^${k}=" "$new" > "${new}.f" || true
  mv "${new}.f" "$new"
done
cat "$frag" >> "$new"
install -m 600 -o root -g root "$new" "$ENVF"
rm -f "$new" "$frag"
# umask を戻してから setup.sh を呼ぶ（077 のままだと setup.sh が作るファイルの
# モードが変わり、root 以外が読む必要のあるものが壊れる）
umask 022
/usr/local/sbin/setup.sh
'
# shellcheck disable=SC2086
printf '%s\n' "$fragment" | $ORENOVPN_SSH "sudo bash -c '$REMOTE_MERGE'"

printf '\n完了しました。`make access-log` / `make dns-log` で記録を確認できます。\n' >&2
