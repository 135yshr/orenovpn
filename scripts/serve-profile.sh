#!/usr/bin/env bash
#
# serve-profile.sh : クライアント構成ファイルを VPS から一時 HTTPS 配信し QR 表示。
#   iPhone の Safari でQRをスキャン → ダウンロード → プロファイル導入。
#
#   前提: 配信ポート（既定443）は Terraform で作成時に SG へ宣言済みであること
#         （ConoHa は後付け SG ルールを稼働中インスタンスに反映しないため）。
#         本スクリプトは SG を変更せず、ufw の開閉と HTTPS 配信のみ行う。
#
#   セキュリティ: 推測不能な URL トークン + 自己署名 HTTPS + 一定時間で自動停止 +
#                 ufw を実行中だけ開く（終了時に必ず閉じる）。
#
#   使い方: make serve-profile NAME=iphone
#     引数: <client-name> <server-ip> <ssh-user>
#     環境: SSH_KEY（任意）, SERVE_PORT（配信ポート）, SERVE_SECONDS（既定180）
#
set -euo pipefail

NAME="${1:-}"; SERVER_IP="${2:-}"; SSH_USER="${3:-}"
DURATION="${SERVE_SECONDS:-180}"
PORT="${SERVE_PORT:-443}"

die(){ echo "エラー: $*" >&2; exit 1; }
[ -n "$NAME" ] && [ -n "$SERVER_IP" ] && [ -n "$SSH_USER" ] || die "引数不足（NAME SERVER_IP SSH_USER）"
command -v curl >/dev/null && command -v python3 >/dev/null || die "curl と python3 が必要です"

SSH_KEY="${SSH_KEY:-}"; SSH_KEY="${SSH_KEY/#\~/$HOME}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[ -n "$SSH_KEY" ] && SSH_OPTS+=(-i "$SSH_KEY")
SSH=(ssh -p 22 "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}")

URLTOKEN=$(python3 -c "import secrets;print(secrets.token_hex(16))")
URL="https://${SERVER_IP}:${PORT}/${URLTOKEN}.mobileconfig"

cleanup() {
  echo; echo "[orenovpn] 後片付け中（ufw を閉じ、配信を停止）..."
  "${SSH[@]}" "sudo pkill -f orenovpn-serve/serve.py >/dev/null 2>&1; sudo ufw delete allow ${PORT}/tcp >/dev/null 2>&1; sudo rm -rf /tmp/orenovpn-serve" >/dev/null 2>&1 || true
  echo "[orenovpn] 完了。"
}
trap cleanup EXIT INT TERM

# --- VPS 側: ufw 開放 + HTTPS 配信をデタッチ起動 + QR 表示 ---
"${SSH[@]}" "PORT='${PORT}' URLTOKEN='${URLTOKEN}' NAME='${NAME}' SERVER_IP='${SERVER_IP}' DURATION='${DURATION}' URL='${URL}' bash -s" <<'REMOTE'
set -e
sudo ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
command -v qrencode >/dev/null 2>&1 || sudo apt-get install -y -qq qrencode >/dev/null 2>&1 || true
sudo rm -rf /tmp/orenovpn-serve; mkdir -p /tmp/orenovpn-serve
SRC="/etc/orenovpn/clients/${NAME}.mobileconfig"
sudo test -f "$SRC" || SRC="/etc/orenovpn/clients/${NAME}.conf"
sudo test -f "$SRC" || { echo "クライアント ${NAME} が見つかりません（make clients で確認）"; exit 1; }
sudo cp "$SRC" "/tmp/orenovpn-serve/${URLTOKEN}.mobileconfig"
sudo chmod 644 "/tmp/orenovpn-serve/${URLTOKEN}.mobileconfig"
sudo openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/orenovpn-serve/key.pem \
  -out /tmp/orenovpn-serve/cert.pem -days 1 -subj "/CN=${SERVER_IP}" >/dev/null 2>&1
cat > /tmp/orenovpn-serve/serve.py <<PY
import http.server, ssl, os
os.chdir('/tmp/orenovpn-serve')
class H(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      '.mobileconfig': 'application/x-apple-aspen-config'}
    def log_message(self, *a): pass
srv = http.server.HTTPServer(('0.0.0.0', int(${PORT})), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain('/tmp/orenovpn-serve/cert.pem', '/tmp/orenovpn-serve/key.pem')
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY
sudo bash -c "nohup timeout ${DURATION} python3 /tmp/orenovpn-serve/serve.py >/tmp/orenovpn-serve/serve.log 2>&1 </dev/null &"
sleep 2
echo "[diag] 待受: $(sudo ss -tlnp 2>/dev/null | grep ":${PORT} " || echo none)"
echo "[diag] serve.log: $(sudo cat /tmp/orenovpn-serve/serve.log 2>/dev/null | tr '\n' ' ' | head -c 200)"
echo
echo "==================== iPhone の Safari でスキャン ===================="
qrencode -t ansiutf8 "${URL}" 2>/dev/null || echo "URL: ${URL}"
echo "URL: ${URL}"
echo "（自己署名のため『安全でない』警告 →『詳細』→『このWebサイトにアクセス』で継続）"
echo "===================================================================="
REMOTE

# --- Mac から到達性テスト ---
echo "[orenovpn] インターネット経由の到達性を確認中..."
sleep 3
code=$(curl -k -sS -m 8 -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null || echo "FAIL")
if [ "$code" = "200" ]; then
  echo "[orenovpn] ✅ 外部から到達OK。iPhone で QR をスキャンしてください。"
else
  echo "[orenovpn] ⚠️ 外部から到達できません（code=${code}）。この出力を貼ってください。"
fi
echo
echo "有効 ${DURATION} 秒。取得後は Ctrl-C で即停止できます。"
sleep "${DURATION}"
