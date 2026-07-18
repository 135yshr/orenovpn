#!/usr/bin/env bash
#
# serve-profile.sh : クライアント構成ファイルを VPS から一時 HTTPS 配信し、
#   QR コードを表示する（iPhone の Safari で直接ダウンロード → プロファイル導入）。
#
#   セキュリティ:
#     - ランダムな高位ポート + 推測不能な URL トークン
#     - 自己署名 HTTPS（平文傍受を防止）
#     - 一定時間で自動停止（既定120秒）
#     - ConoHa SG と ufw のポートを開始時に開き、終了時に必ず閉じる
#   ※ 鍵入りファイルを一時的にインターネット配信するため、取得したら速やかに終了すること。
#
#   使い方: make serve-profile NAME=iphone   （直接実行も可）
#     引数: <client-name> <server-ip> <ssh-user>
#     環境: SSH_KEY（任意）, SERVE_SECONDS（既定120）
#
set -euo pipefail

NAME="${1:-}"; SERVER_IP="${2:-}"; SSH_USER="${3:-}"
DURATION="${SERVE_SECONDS:-120}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="${SCRIPT_DIR}/../terraform/terraform.tfvars"

die(){ echo "エラー: $*" >&2; exit 1; }
[ -n "$NAME" ] && [ -n "$SERVER_IP" ] && [ -n "$SSH_USER" ] || die "引数不足（NAME SERVER_IP SSH_USER）"
command -v curl >/dev/null && command -v python3 >/dev/null || die "curl と python3 が必要です"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
SSH_KEY="${SSH_KEY:-}"
SSH_KEY="${SSH_KEY/#\~/$HOME}" # 先頭の ~ を展開（クォート内では自動展開されないため）
[ -n "$SSH_KEY" ] && SSH_OPTS+=(-i "$SSH_KEY")
SSH=(ssh -p 22 "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}")

getv(){ { grep -E "^[[:space:]]*$1[[:space:]]*=" "$TFVARS" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*[^"# ])"?.*$/\1/'; } || true; }
AUTH="${OS_AUTH_URL:-$(getv conoha_auth_url)}"; AUTH="${AUTH:-https://identity.c3j1.conoha.io/v3}"
DOM="${OS_USER_DOMAIN_NAME:-$(getv conoha_domain_name)}"; DOM="${DOM:-gnc}"
TEN="$(getv conoha_tenant_name)"; USR="$(getv conoha_user_name)"; PW="$(getv conoha_password)"
[ -n "$TEN" ] && [ -n "$USR" ] && [ -n "$PW" ] || die "認証情報が読めません（terraform.tfvars）"

# --- Keystone 認証 & Network エンドポイント取得 ---
hdr="$(mktemp)"; bdy="$(mktemp)"
payload=$(python3 - "$USR" "$DOM" "$PW" "$TEN" <<'PY'
import json,sys
u,d,p,t=sys.argv[1:5]
print(json.dumps({"auth":{"identity":{"methods":["password"],"password":{"user":{"name":u,"domain":{"name":d},"password":p}}},"scope":{"project":{"name":t,"domain":{"name":d}}}}}))
PY
)
curl -sS -X POST "${AUTH%/}/auth/tokens" -H 'Content-Type: application/json' -d "$payload" -D "$hdr" -o "$bdy"
TOKEN="$(awk 'tolower($1)=="x-subject-token:"{print $2}' "$hdr" | tr -d '\r\n')"
[ -n "$TOKEN" ] || die "ConoHa 認証に失敗"
NEP="$(python3 -c "import json;d=json.load(open('$bdy'));print([e['url'].rstrip('/') for s in d['token']['catalog'] if s['type']=='network' for e in s['endpoints'] if e['interface']=='public'][0])")"
SGID="$(curl -sS "$NEP/v2.0/security-groups?name=orenovpn-sg" -H "X-Auth-Token: $TOKEN" | python3 -c "import json,sys;print(json.load(sys.stdin)['security_groups'][0]['id'])")"
rm -f "$hdr" "$bdy"

# --- ランダムなポート/トークン ---
# 既定はランダム高位ポート。SERVE_PORT=443 等を指定するとキャリアの遮断を回避しやすい。
PORT="${SERVE_PORT:-$(python3 -c "import secrets;print(secrets.randbelow(20000)+40000)")}"
URLTOKEN=$(python3 -c "import secrets;print(secrets.token_hex(16))")
RULE_ID=""

cleanup() {
  echo; echo "[orenovpn] 後片付け中（ファイアウォールを閉じます）..."
  [ -n "$RULE_ID" ] && curl -sS -X DELETE "$NEP/v2.0/security-group-rules/$RULE_ID" -H "X-Auth-Token: $TOKEN" >/dev/null 2>&1 || true
  "${SSH[@]}" "sudo pkill -f orenovpn-serve/serve.py >/dev/null 2>&1; sudo ufw delete allow ${PORT}/tcp >/dev/null 2>&1; sudo rm -rf /tmp/orenovpn-serve" >/dev/null 2>&1 || true
  echo "[orenovpn] 完了。ポート ${PORT} は閉じました。"
}
trap cleanup EXIT INT TERM

# --- ConoHa SG に一時ルール追加（tcp PORT）---
echo "[orenovpn] SG に一時ポート ${PORT}/tcp を開放..."
RULE_ID=$(curl -sS -X POST "$NEP/v2.0/security-group-rules" -H "X-Auth-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"security_group_rule\":{\"direction\":\"ingress\",\"ethertype\":\"IPv4\",\"protocol\":\"tcp\",\"port_range_min\":${PORT},\"port_range_max\":${PORT},\"remote_ip_prefix\":\"0.0.0.0/0\",\"security_group_id\":\"${SGID}\"}}" \
  | python3 -c "import json,sys;r=json.load(sys.stdin).get('security_group_rule');print(r['id'] if r else '')")
[ -n "$RULE_ID" ] || die "SG ルール追加に失敗"

URL="https://${SERVER_IP}:${PORT}/${URLTOKEN}.mobileconfig"

# --- VPS 側で HTTPS 配信をデタッチ起動 + QR 表示（サーバーは timeout で自動停止）---
"${SSH[@]}" "PORT='${PORT}' URLTOKEN='${URLTOKEN}' NAME='${NAME}' SERVER_IP='${SERVER_IP}' DURATION='${DURATION}' URL='${URL}' bash -s" <<'REMOTE'
set -e
sudo ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
command -v qrencode >/dev/null 2>&1 || sudo apt-get install -y -qq qrencode >/dev/null 2>&1 || true
sudo rm -rf /tmp/orenovpn-serve; mkdir -p /tmp/orenovpn-serve
SRC="/etc/orenovpn/clients/${NAME}.mobileconfig"
sudo test -f "$SRC" || SRC="/etc/orenovpn/clients/${NAME}.conf"
sudo test -f "$SRC" || { echo "クライアント ${NAME} が見つかりません（/etc/orenovpn/clients 配下）"; exit 1; }
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
# デタッチ起動（timeout で自動停止。SSH セッション終了後も生存）
sudo bash -c "nohup timeout ${DURATION} python3 /tmp/orenovpn-serve/serve.py >/tmp/orenovpn-serve/serve.log 2>&1 </dev/null &"
sleep 2
echo "[diag] python 待受: $(sudo ss -tlnp 2>/dev/null | grep ":${PORT} " || echo '(待受なし)')"
echo "[diag] ufw: $(sudo ufw status 2>/dev/null | grep "${PORT}" || echo '(ルールなし)')"
echo "[diag] serve.log: $(sudo cat /tmp/orenovpn-serve/serve.log 2>/dev/null | tr '\n' ' ' | head -c 300)"
echo
echo "==================== iPhone の Safari でスキャン ===================="
qrencode -t ansiutf8 "${URL}" 2>/dev/null || echo "URL: ${URL}"
echo "URL: ${URL}"
echo "（自己署名のため『安全でない』警告 →『詳細』→『このWebサイトにアクセス』で継続）"
echo "===================================================================="
REMOTE

# --- Mac 自身からの到達性テスト（SG が効いているかの切り分け）---
echo "[orenovpn] インターネット経由の到達性を確認中..."
sleep 3
code=$(curl -k -sS -m 8 -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null || echo "FAIL")
if [ "$code" = "200" ]; then
  echo "[orenovpn] ✅ Mac から到達OK（ポート ${PORT} は外部公開されています）"
  echo "           → iPhone で繋がらない場合は、モバイル回線が高位ポートを遮断している可能性大。"
  echo "             Wi-Fi に切り替えて試すか、SERVE_PORT=443 を指定して再実行してください。"
else
  echo "[orenovpn] ⚠️ Mac からも到達できません（code=${code}）。SG/ufw/経路の問題です。"
  echo "           → この結果を貼ってください。SG 動的ルールの適用可否を調べます。"
fi

echo
echo "有効 ${DURATION} 秒。iPhone で QR をスキャンしてください。Ctrl-C で即停止できます。"
sleep "${DURATION}"
