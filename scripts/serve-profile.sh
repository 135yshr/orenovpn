#!/usr/bin/env bash
#
# serve-profile.sh : クライアント構成ファイルを VPS から一時 HTTPS 配信し QR 表示。
#   iPhone の Safari でQRをスキャン → ダウンロード → プロファイル導入。
#
#   前提: 配信ポート（既定443）は Terraform で作成時に SG へ宣言済みであること
#         （ConoHa は後付け SG ルールを稼働中インスタンスに反映しないため）。
#         本スクリプトは SG を変更せず、ufw の開閉と HTTPS 配信のみ行う。
#
#   証明書: 既定で Let's Encrypt の信頼された証明書を取得し、ブラウザ警告を出さない。
#           ホスト名は <IP>.sslip.io（IP に解決される公開ワイルドカードDNS）を使う。
#           取得済み証明書はサーバーにキャッシュして再利用（LE レート制限を回避）。
#           取得できない場合は自己署名にフォールバック（Safari で手動承認が必要）。
#
#   セキュリティ: 推測不能な URL トークン + HTTPS + 一定時間で自動停止 +
#                 ufw を実行中だけ開く（終了時に必ず閉じる）。
#
#   使い方: make serve-profile NAME=iphone
#     引数: <client-name> <server-ip> <ssh-user>
#     環境: SSH_KEY（任意）, SERVE_PORT（配信ポート）, SERVE_SECONDS（既定180）,
#           PROFILE_DOMAIN（任意・自分のドメイン。A レコードを本 IP に向けておく）
#
set -euo pipefail

NAME="${1:-}"; SERVER_IP="${2:-}"; SSH_USER="${3:-}"
DURATION="${SERVE_SECONDS:-180}"
PORT="${SERVE_PORT:-443}"

die(){ echo "エラー: $*" >&2; exit 1; }
[ -n "$NAME" ] && [ -n "$SERVER_IP" ] && [ -n "$SSH_USER" ] || die "引数不足（NAME SERVER_IP SSH_USER）"
# NAME はリモートのコマンド/パスに埋め込むため、英数字・ハイフン・アンダースコアのみ許可。
[[ "$NAME" =~ ^[A-Za-z0-9_-]+$ ]] || die "NAME は英数字・ハイフン・アンダースコアのみ使用できます"
command -v curl >/dev/null && command -v python3 >/dev/null || die "curl と python3 が必要です"

SSH_KEY="${SSH_KEY:-}"; SSH_KEY="${SSH_KEY/#\~/$HOME}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[ -n "$SSH_KEY" ] && SSH_OPTS+=(-i "$SSH_KEY")
SSH=(ssh -p 22 "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}")

# 配信ホスト名: 既定は <IP>.sslip.io（IP に解決される公開ワイルドカードDNS）。
# 自分のドメインがあれば PROFILE_DOMAIN=vpn.example.com のように指定（A レコードを本 IP へ）。
HOST="${PROFILE_DOMAIN:-${SERVER_IP}.sslip.io}"
URLTOKEN=$(python3 -c "import secrets;print(secrets.token_hex(16))")
URL="https://${HOST}:${PORT}/${URLTOKEN}.mobileconfig"

cleanup() {
  # INT/TERM で発火した後に EXIT でも再発火して二重実行になるのを防ぐ。
  trap - EXIT INT TERM
  echo; echo "[orenovpn] 後片付け中（ufw を閉じ、配信を停止）..."
  "${SSH[@]}" "sudo pkill -f orenovpn-serve/serve.py >/dev/null 2>&1; sudo ufw delete allow ${PORT}/tcp >/dev/null 2>&1; sudo ufw delete allow 80/tcp >/dev/null 2>&1; sudo rm -rf /tmp/orenovpn-serve" >/dev/null 2>&1 || true
  echo "[orenovpn] 完了。"
}
trap cleanup EXIT INT TERM

# --- VPS 側: ufw 開放 + HTTPS 配信をデタッチ起動 + QR 表示 ---
"${SSH[@]}" "PORT='${PORT}' URLTOKEN='${URLTOKEN}' NAME='${NAME}' SERVER_IP='${SERVER_IP}' HOST='${HOST}' DURATION='${DURATION}' URL='${URL}' bash -s" <<'REMOTE'
set -e
sudo ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
command -v qrencode >/dev/null 2>&1 || sudo apt-get install -y -qq qrencode >/dev/null 2>&1 || true
sudo rm -rf /tmp/orenovpn-serve; mkdir -p /tmp/orenovpn-serve
SRC="/etc/orenovpn/clients/${NAME}.mobileconfig"
sudo test -f "$SRC" || SRC="/etc/orenovpn/clients/${NAME}.conf"
sudo test -f "$SRC" || { echo "クライアント ${NAME} が見つかりません（make clients で確認）"; exit 1; }
sudo cp "$SRC" "/tmp/orenovpn-serve/${URLTOKEN}.mobileconfig"
sudo chmod 644 "/tmp/orenovpn-serve/${URLTOKEN}.mobileconfig"

# --- 証明書: Let's Encrypt(信頼済み) を優先、失敗時は自己署名にフォールバック ---
CERTDIR=/etc/orenovpn/serve-cert
sudo mkdir -p "$CERTDIR"
TRUSTED=0
# 30日以上有効なキャッシュがあれば再利用（LE レート制限を避ける）
if sudo test -f "${CERTDIR}/${HOST}.crt" && sudo test -f "${CERTDIR}/${HOST}.key" \
   && sudo openssl x509 -checkend $((30*24*3600)) -noout -in "${CERTDIR}/${HOST}.crt" >/dev/null 2>&1; then
  echo "[cert] キャッシュ済みの証明書を再利用します（${HOST}）"
  TRUSTED=1
else
  command -v certbot >/dev/null 2>&1 || sudo apt-get install -y -qq certbot >/dev/null 2>&1 || true
  if command -v certbot >/dev/null 2>&1; then
    sudo ufw allow 80/tcp >/dev/null 2>&1 || true
    echo "[cert] Let's Encrypt 証明書を取得中（${HOST} / HTTP-01・ポート80）..."
    if sudo certbot certonly --standalone --non-interactive --agree-tos \
         --register-unsafely-without-email --http-01-port 80 \
         -d "${HOST}" >/tmp/orenovpn-serve/certbot.log 2>&1; then
      sudo cp "/etc/letsencrypt/live/${HOST}/fullchain.pem" "${CERTDIR}/${HOST}.crt"
      sudo cp "/etc/letsencrypt/live/${HOST}/privkey.pem"   "${CERTDIR}/${HOST}.key"
      echo "[cert] 取得成功。"
      TRUSTED=1
    else
      echo "[cert] 取得失敗（レート制限/到達不可の可能性）。certbot.log 末尾:"
      sudo tail -n 4 /tmp/orenovpn-serve/certbot.log 2>/dev/null || true
    fi
    sudo ufw delete allow 80/tcp >/dev/null 2>&1 || true
  fi
fi

if [ "$TRUSTED" = 1 ]; then
  sudo cp "${CERTDIR}/${HOST}.crt" /tmp/orenovpn-serve/cert.pem
  sudo cp "${CERTDIR}/${HOST}.key" /tmp/orenovpn-serve/key.pem
else
  echo "[cert] 自己署名にフォールバックします（Safari で警告→手動承認が必要）。"
  sudo openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/orenovpn-serve/key.pem \
    -out /tmp/orenovpn-serve/cert.pem -days 1 -subj "/CN=${HOST}" >/dev/null 2>&1
fi

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
echo "[diag] ufw: $(sudo ufw status 2>/dev/null | grep -E "(^|[^0-9])${PORT}(/|[^0-9])" | tr '\n' ' ' || echo none)"
echo "[diag] localhost: $(curl -k -sS -m5 -o /dev/null -w '%{http_code}' "https://127.0.0.1:${PORT}/${URLTOKEN}.mobileconfig" 2>/dev/null || echo FAIL)"
echo "[diag] serve.log: $(sudo cat /tmp/orenovpn-serve/serve.log 2>/dev/null | tr '\n' ' ' | head -c 200)"
echo
echo "==================== iPhone の Safari でスキャン ===================="
qrencode -t ansiutf8 "${URL}" 2>/dev/null || echo "URL: ${URL}"
echo "URL: ${URL}"
if [ "$TRUSTED" = 1 ]; then
  echo "（信頼された証明書です。警告は出ません。そのままダウンロード→インストール）"
else
  echo "（自己署名のため『安全でない』警告 →『詳細』→『このWebサイトにアクセス』で継続）"
fi
echo "===================================================================="
REMOTE

# --- Mac から到達性テスト ---
echo "[orenovpn] インターネット経由の到達性を確認中..."
sleep 3
code=$(curl -k -sS -m 8 -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null || echo "FAIL")
if [ "$code" = "200" ]; then
  # 証明書検証あり(-k なし)でも 200 なら「信頼された証明書」= iPhone で警告なし。
  if curl -sS -m 8 -o /dev/null "$URL" 2>/dev/null; then
    echo "[orenovpn] ✅ 外部から到達OK / 信頼された証明書。iPhone で QR をスキャンすれば警告なしで導入できます。"
  else
    echo "[orenovpn] ✅ 外部から到達OK（証明書は自己署名）。iPhone では警告→手動承認で進めてください。"
  fi
else
  echo "[orenovpn] ⚠️ 外部から到達できません（code=${code}）。この出力を貼ってください。"
fi
echo
echo "有効 ${DURATION} 秒。取得後は Ctrl-C で即停止できます。"
sleep "${DURATION}"
