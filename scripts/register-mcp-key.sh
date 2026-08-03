#!/usr/bin/env bash
#
# register-mcp-key.sh : MCP 用の公開鍵を forced command 付きで authorized_keys へ
#   登録する（make mcp-key）。make 経由で ORENOVPN_SSH に SSH コマンドを受け取る。
#
#   環境変数: PUBKEY=<公開鍵のパス>（既定 ~/.ssh/orenovpn-mcp.pub）
#
#   手順書に素の ssh を書くと admin 鍵（SSH_KEY / orenovpn.local.mk）が渡らず
#   "Permission denied (publickey)" になるため、接続は必ず Makefile の $(SSH) を通す。
#
# ---------------------------------------------------------------------------
# ここで守る不変条件（破ると admin の全権を渡した鍵ができる）:
#   - 追記する行は**このスクリプトが組み立てた 1 行だけ**。公開鍵ファイルを
#     そのまま流し込まない（複数行の .pub を cat すると 2 本目以降が
#     forced command 無しで入り、無制限の鍵になる）
#   - 鍵種別と本体は型で検証する。鍵コメントは元ファイルの値を使わず
#     "orenovpn-mcp" に固定する（任意の文字列が入りうるため。doctor.sh は
#     このコメントで MCP 用の鍵を識別する）
#   - 同じ鍵が forced command 無しで既に入っていたら、登録済み扱いにせず失敗させる
#     （黙って通すと doctor.sh が FAIL にする状態を作ったまま「成功」と表示される）
#   - 検査と追記は 1 回の SSH の中で flock 下に行う（別々のセッションに分けると
#     並行実行で二重登録しうる）
# ---------------------------------------------------------------------------
#
# macOS 標準の bash は 3.2 なので、mapfile 等の bash 4 以降の機能は使わない。
#
set -euo pipefail

: "${ORENOVPN_SSH:?make mcp-key 経由で実行してください（ORENOVPN_SSH 未設定）}"

FORCED_COMMAND='command="/usr/local/sbin/orenovpn-mcp-shell",restrict'
KEY_COMMENT=orenovpn-mcp

die() { echo "エラー: $*" >&2; exit 1; }

PUB="${PUBKEY:-}"
[ -n "$PUB" ] || PUB="$HOME/.ssh/orenovpn-mcp.pub"
# make の変数や orenovpn.local.mk 経由だとチルダが展開されずに届く
# （zsh はコマンド引数の "=" の後をチルダ展開しない）。ここで展開する。
# TILDE を変数にするのは、リテラルの "~" を照合する意図をシェルにも読み手にも
# 明示するため（クォートした "~" は展開されない、という警告と紛らわしいので分ける）。
TILDE='~'
case "$PUB" in
  "$TILDE") PUB="$HOME" ;;
  "$TILDE"/*) PUB="$HOME/${PUB#"$TILDE"/}" ;;
esac

[ -f "$PUB" ] || die "公開鍵が見つかりません: ${PUB}
→ ssh-keygen -t ed25519 -f ~/.ssh/orenovpn-mcp -C orenovpn-mcp -N '' で作成してください"

# 空行とコメント行を除いた実体行だけを見る。鍵が 2 本以上あるファイルは受け付けない。
COUNT=0
FIRST=""
while IFS= read -r line; do
  case "$line" in
    ''|'#'*|[[:space:]]*) [ -n "${line//[[:space:]]/}" ] || continue ;;
  esac
  COUNT=$((COUNT + 1))
  [ "$COUNT" -eq 1 ] && FIRST="$line"
done < "$PUB"
[ "$COUNT" -eq 1 ] || die "公開鍵ファイルには鍵を 1 本だけ書いてください（検出: ${COUNT} 本）: ${PUB}"

read -r KEYTYPE KEYBODY _ <<<"$FIRST"
case "$KEYTYPE" in
  ssh-ed25519|ssh-rsa|ssh-dss) ;;
  ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ;;
  sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
  *) die "対応していない鍵種別です（${KEYTYPE:-空}）: ${PUB}" ;;
esac
case "$KEYBODY" in
  ''|*[!A-Za-z0-9+/=]*) die "公開鍵の本体が base64 ではありません: ${PUB}" ;;
esac

# 追記する行はここで組み立てる。以降サーバーへ渡すのはこの 1 行だけ。
LINE="${FORCED_COMMAND} ${KEYTYPE} ${KEYBODY} ${KEY_COMMENT}"

# サーバー側の処理。行は標準入力で受け取る（引数に埋めるとクォートの解釈が挟まる）。
# 判定は 1 回の接続の中で flock 下に行い、結果を 1 語で返す。
REMOTE='
set -eu
umask 077
mkdir -p "$HOME/.ssh"
AK="$HOME/.ssh/authorized_keys"
touch "$AK"
line="$(cat)"
body="$(printf %s "$line" | cut -d" " -f3)"
apply() {
  if grep -qxF "$line" "$AK"; then echo REGISTERED; return 0; fi
  if grep -qF "$body" "$AK"; then echo CONFLICT; return 0; fi
  # 末尾に改行が無いと直前の行と連結し、両方の鍵が壊れる
  if [ -s "$AK" ] && [ -n "$(tail -c 1 "$AK")" ]; then printf "\n" >>"$AK"; fi
  printf "%s\n" "$line" >>"$AK"
  echo ADDED
}
if command -v flock >/dev/null 2>&1; then
  exec 9>"$HOME/.ssh/.orenovpn-mcp-key.lock"
  flock 9
fi
apply
'

# shellcheck disable=SC2086
RESULT="$(printf '%s\n' "$LINE" | $ORENOVPN_SSH "$REMOTE")" \
  || die "サーバーへの接続または authorized_keys の更新に失敗しました"

case "$RESULT" in
  ADDED)      echo "登録しました。" ;;
  REGISTERED) echo "既に登録済みです（重複して追記しません）。" ;;
  CONFLICT)
    die "同じ公開鍵が forced command 無しで authorized_keys に入っています。
   そのままでは admin の全権を持つ鍵になります（make doctor が FAIL にします）。
   サーバー上で該当行を削除してから、もう一度 make mcp-key を実行してください:
     ssh ... 'grep -n \"${KEYBODY}\" ~/.ssh/authorized_keys'"
    ;;
  *) die "サーバーの応答を解釈できません: ${RESULT}" ;;
esac

echo "--- authorized_keys の該当行（オプションが鍵種別より前にあること）---"
# shellcheck disable=SC2086
$ORENOVPN_SSH "grep -F '${KEYBODY}' ~/.ssh/authorized_keys" \
  || die "登録後の確認に失敗しました（authorized_keys を直接確認してください）"

echo "→ 確認: make doctor / ssh -i ${PUB%.pub} <admin_user>@<server_ip> clients"
