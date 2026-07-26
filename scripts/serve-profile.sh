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
#   セキュリティ（配信物は資格情報そのものなので多層で守る）:
#     - トークン一致のパスだけを返す専用ハンドラ。ディレクトリ一覧・パス探索は不可。
#       ※ SimpleHTTPRequestHandler は index の無いディレクトリに autoindex を返し、
#         URL トークンが列挙されて防御が完全に無効になる。絶対に戻さないこと。
#     - Host ヘッダが配信ホスト名と一致しない要求は拒否（IP 直打ちスキャンを弾く）
#     - 配布物はサーバー上の root 専有パスから直接読み、/tmp に複製しない
#     - ダウンロード回数の上限（既定2回）に達したら即停止
#     - 一定時間で自動停止。サーバー側 watchdog が ufw も必ず閉じる（手元の Ctrl-C や
#       回線状態に依存しない）
#     - 許可/拒否は /var/log/orenovpn-serve.log に残し、後から証跡を追える
#
#   使い方: make serve-profile NAME=iphone
#     引数: <client-name> <server-ip> <ssh-user>
#     環境: SSH_KEY（任意）, SERVE_PORT（配信ポート）, SERVE_SECONDS（既定180）,
#           SERVE_MAX_DOWNLOADS（既定2）,
#           PROFILE_DOMAIN（任意・自分のドメイン。A レコードを本 IP に向けておく）
#
set -euo pipefail

NAME="${1:-}"; SERVER_IP="${2:-}"; SSH_USER="${3:-}"
DURATION="${SERVE_SECONDS:-180}"
PORT="${SERVE_PORT:-443}"
MAXDL="${SERVE_MAX_DOWNLOADS:-2}"

die(){ echo "エラー: $*" >&2; exit 1; }
[ -n "$NAME" ] && [ -n "$SERVER_IP" ] && [ -n "$SSH_USER" ] || die "引数不足（NAME SERVER_IP SSH_USER）"
# リモートのコマンド列と Python ソースへ埋め込む値は、すべて厳格に検証する
# （未検証の値を埋め込むとリモートでのコード注入になる）。
[[ "$NAME" =~ ^[A-Za-z0-9_-]+$ ]] || die "NAME は英数字・ハイフン・アンダースコアのみ使用できます"
[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "SERVE_PORT が不正です: ${PORT}"
[[ "$DURATION" =~ ^[0-9]+$ ]] && [ "$DURATION" -ge 10 ] || die "SERVE_SECONDS は 10 以上の秒数で指定してください: ${DURATION}"
[[ "$MAXDL" =~ ^[0-9]+$ ]] && [ "$MAXDL" -ge 1 ] || die "SERVE_MAX_DOWNLOADS は 1 以上で指定してください: ${MAXDL}"
[[ "$SERVER_IP" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "SERVER_IP が不正です: ${SERVER_IP}"
if [ -n "${PROFILE_DOMAIN:-}" ]; then
  [[ "$PROFILE_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "PROFILE_DOMAIN が不正です: ${PROFILE_DOMAIN}"
fi
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
  # サーバー側 watchdog も同じ後片付けを行うが、こちらが先に走れば露出時間が短くなる。
  # access ログ(/var/log/orenovpn-serve.log)は証跡のため消さない。
  # 80/tcp は LE の HTTP-01 用に一時開放されるため、途中で切れた場合に備えて必ず閉じる。
  "${SSH[@]}" "sudo pkill -f orenovpn-serve/serve.py >/dev/null 2>&1; sudo ufw delete allow ${PORT}/tcp >/dev/null 2>&1; sudo ufw delete allow 80/tcp >/dev/null 2>&1; sudo rm -rf /run/orenovpn-serve /tmp/orenovpn-serve" >/dev/null 2>&1 || true
  echo "[orenovpn] 完了。要求の記録: sudo tail /var/log/orenovpn-serve.log"
}
trap cleanup EXIT INT TERM

# --- VPS 側: HTTPS 配信をデタッチ起動 → ufw 開放 → QR 表示 ---
# 作業ディレクトリは root 専有(0700)の /run 配下。配布物は複製せず元パスから読む。
"${SSH[@]}" "PORT='${PORT}' URLTOKEN='${URLTOKEN}' NAME='${NAME}' SERVER_IP='${SERVER_IP}' HOST='${HOST}' DURATION='${DURATION}' MAXDL='${MAXDL}' URL='${URL}' bash -s" <<'REMOTE'
set -e
RUNDIR=/run/orenovpn-serve
ACCESSLOG=/var/log/orenovpn-serve.log
command -v qrencode >/dev/null 2>&1 || sudo apt-get install -y -qq qrencode >/dev/null 2>&1 || true
sudo rm -rf "$RUNDIR" /tmp/orenovpn-serve
sudo install -d -m 0700 -o root -g root "$RUNDIR"
sudo touch "$ACCESSLOG"; sudo chmod 600 "$ACCESSLOG"

# 配布物はコピーしない（/tmp への world-readable な複製が露出源だった）。
# root だけが読める元パスを配信サーバーが直接読む。
SRC="/etc/orenovpn/clients/${NAME}.mobileconfig"
DLNAME="${NAME}.mobileconfig"
CTYPE="application/x-apple-aspen-config"
if ! sudo test -f "$SRC"; then
  SRC="/etc/orenovpn/clients/${NAME}.conf"
  DLNAME="${NAME}.conf"
  CTYPE="text/plain; charset=utf-8"
fi
sudo test -f "$SRC" || { echo "クライアント ${NAME} が見つかりません（make clients で確認）"; exit 1; }

# --- 証明書: Let's Encrypt(信頼済み) を優先、失敗時は自己署名にフォールバック ---
CERTDIR=/etc/orenovpn/serve-cert
sudo install -d -m 0700 -o root -g root "$CERTDIR"
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
    # ログの書き込み先は root 専有(0700)のため、リダイレクトも root で行う。
    if sudo bash -c "certbot certonly --standalone --non-interactive --agree-tos \
         --register-unsafely-without-email --http-01-port 80 \
         -d '${HOST}' >'${RUNDIR}/certbot.log' 2>&1"; then
      sudo install -m 0600 -o root -g root "/etc/letsencrypt/live/${HOST}/fullchain.pem" "${CERTDIR}/${HOST}.crt"
      sudo install -m 0600 -o root -g root "/etc/letsencrypt/live/${HOST}/privkey.pem"   "${CERTDIR}/${HOST}.key"
      echo "[cert] 取得成功。"
      TRUSTED=1
    else
      echo "[cert] 取得失敗（レート制限/到達不可の可能性）。certbot.log 末尾:"
      sudo tail -n 4 "${RUNDIR}/certbot.log" 2>/dev/null || true
    fi
    sudo ufw delete allow 80/tcp >/dev/null 2>&1 || true
  fi
fi
# 注意: 証明書を取得すると <HOST> は Certificate Transparency ログに即時公開される
# （攻撃者に「このIPで配信が始まった」ことが数秒で伝わる）。だからこそ下の
# トークン一致・Host 一致・回数上限・自動停止をすべて必須にしている。

if [ "$TRUSTED" = 1 ]; then
  sudo install -m 0600 -o root -g root "${CERTDIR}/${HOST}.crt" "${RUNDIR}/cert.pem"
  sudo install -m 0600 -o root -g root "${CERTDIR}/${HOST}.key" "${RUNDIR}/key.pem"
else
  echo "[cert] 自己署名にフォールバックします（Safari で警告→手動承認が必要）。"
  sudo openssl req -x509 -newkey rsa:2048 -nodes -keyout "${RUNDIR}/key.pem" \
    -out "${RUNDIR}/cert.pem" -days 1 -subj "/CN=${HOST}" >/dev/null 2>&1
  sudo chmod 600 "${RUNDIR}/key.pem" "${RUNDIR}/cert.pem"
fi

# --- 配信サーバー本体 -------------------------------------------------------
sudo tee "${RUNDIR}/serve.py" >/dev/null <<PY
# orenovpn 一時配信サーバー（serve-profile.sh が生成）。
# トークン一致 + Host 一致 + 回数上限を満たす要求だけに配布物を返す。
import hmac, http.server, os, ssl, threading

WANT_PATH = b"/${URLTOKEN}.mobileconfig"
WANT_HOST = b"${HOST}".lower()
SRC       = "${SRC}"
DLNAME    = "${DLNAME}"
CTYPE     = "${CTYPE}"
MAXDL     = int("${MAXDL}")
LOGFILE   = "${ACCESSLOG}"

state_lock = threading.Lock()
downloads  = 0


def audit(ip, verdict, detail):
    try:
        with open(LOGFILE, "a") as f:
            f.write("%s %s %s\n" % (ip, verdict, detail))
    except OSError:
        pass


def stop_soon():
    # レスポンスを送り切ってから終了する（露出時間を最小化）。
    threading.Timer(1.0, lambda: os._exit(0)).start()


def eq(a, b):
    return len(a) == len(b) and hmac.compare_digest(a, b)


class H(http.server.BaseHTTPRequestHandler):
    server_version = "orenovpn"
    sys_version = ""
    timeout = 10  # 接続を握られて配布を妨害されないように

    def log_message(self, *a):
        pass

    def _host_ok(self):
        host = (self.headers.get("Host") or "").strip().lower()
        if host.startswith("["):          # IPv6 リテラル [::1]:443
            host = host.split("]", 1)[0] + "]"
        elif ":" in host:
            host = host.rsplit(":", 1)[0]
        return eq(host.encode("utf-8", "replace"), WANT_HOST)

    def _path_ok(self):
        path = self.path.split("?", 1)[0].split("#", 1)[0]
        return eq(path.encode("utf-8", "replace"), WANT_PATH)

    def _deny(self, reason, head):
        audit(self.client_address[0], "DENY", "%s %s %s" % (reason, self.command, self.path[:80]))
        body = b"Not Found\n"
        self.send_response(404)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if not head:
            self.wfile.write(body)

    def _handle(self, head):
        global downloads
        if not self._host_ok():
            self._deny("host-mismatch", head)
            return
        if not self._path_ok():
            self._deny("token-mismatch", head)
            return
        try:
            with open(SRC, "rb") as f:
                data = f.read()
        except OSError:
            self._deny("source-missing", head)
            return
        last = False
        if not head:
            # HEAD は到達性・証明書の確認用。ダウンロード回数には数えない。
            with state_lock:
                if downloads >= MAXDL:
                    over = True
                else:
                    downloads += 1
                    over = False
                    last = downloads >= MAXDL
            if over:
                self._deny("limit-exceeded", head)
                return
        self.send_response(200)
        self.send_header("Content-Type", CTYPE)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % DLNAME)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        if head:
            audit(self.client_address[0], "HEAD-OK", DLNAME)
            return
        self.wfile.write(data)
        self.wfile.flush()
        audit(self.client_address[0], "SERVED", DLNAME)
        if last:
            audit(self.client_address[0], "STOP", "download limit reached")
            stop_soon()

    def do_HEAD(self):
        self._handle(True)

    def do_GET(self):
        self._handle(False)


srv = http.server.ThreadingHTTPServer(("0.0.0.0", int("${PORT}")), H)
srv.daemon_threads = True
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.minimum_version = ssl.TLSVersion.TLSv1_2
ctx.load_cert_chain("${RUNDIR}/cert.pem", "${RUNDIR}/key.pem")
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY
sudo chmod 600 "${RUNDIR}/serve.py"

# 先に待受を上げ、リッスンを確認してから ufw を開ける（開いている時間を最短にする）。
SPID="$(sudo bash -c "nohup timeout ${DURATION} python3 ${RUNDIR}/serve.py >${RUNDIR}/serve.log 2>&1 </dev/null & echo \$!")"

# サーバー側 watchdog: 手元の Ctrl-C / 回線切断 / SIGKILL に依存せず必ず閉じる。
# （旧実装は手元スクリプトの trap だけが後片付けを担っていたため、切断時に ufw の穴と
#   平文の配布物が残り続けた。）他の配信が動いていればポートは閉じない。
sudo setsid nohup bash -c "sleep $((DURATION + 30)); kill ${SPID} >/dev/null 2>&1; sleep 1; pgrep -f 'orenovpn-serve/serve.py' >/dev/null 2>&1 || { ufw delete allow ${PORT}/tcp >/dev/null 2>&1; ufw delete allow 80/tcp >/dev/null 2>&1; rm -rf ${RUNDIR}; }" >/dev/null 2>&1 </dev/null &

sleep 2
if ! sudo ss -tln 2>/dev/null | grep -q ":${PORT} "; then
  echo "[diag] 待受の起動に失敗しました。serve.log:"
  sudo head -c 400 "${RUNDIR}/serve.log" 2>/dev/null || true
  sudo pkill -f orenovpn-serve/serve.py >/dev/null 2>&1 || true
  exit 1
fi
sudo ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true

echo "[diag] 待受: $(sudo ss -tlnp 2>/dev/null | grep ":${PORT} " || echo none)"
echo "[diag] ufw: $(sudo ufw status 2>/dev/null | grep -E "(^|[^0-9])${PORT}(/|[^0-9])" | tr '\n' ' ' || echo none)"
# 確認は HEAD で行う（GET はダウンロード回数を消費する）。Host 一致が必須なので付与する。
echo "[diag] localhost: $(curl -k -sS -m5 -I -H "Host: ${HOST}" -o /dev/null -w '%{http_code}' "https://127.0.0.1:${PORT}/${URLTOKEN}.mobileconfig" 2>/dev/null || echo FAIL)"
echo
echo "==================== iPhone の Safari でスキャン ===================="
qrencode -t ansiutf8 "${URL}" 2>/dev/null || echo "URL: ${URL}"
echo "URL: ${URL}"
if [ "$TRUSTED" = 1 ]; then
  echo "（信頼された証明書です。警告は出ません。そのままダウンロード→インストール）"
else
  echo "（自己署名のため『安全でない』警告 →『詳細』→『このWebサイトにアクセス』で継続）"
fi
echo "（ダウンロード ${MAXDL} 回で自動停止。${DURATION} 秒後には watchdog が必ず閉じます）"
echo "===================================================================="
REMOTE

# --- Mac から到達性テスト（HEAD。ダウンロード回数を消費しない）---
echo "[orenovpn] インターネット経由の到達性を確認中..."
sleep 3
code=$(curl -k -sS -m 8 -I -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null || echo "FAIL")
if [ "$code" = "200" ]; then
  # 証明書検証あり(-k なし)でも 200 なら「信頼された証明書」= iPhone で警告なし。
  if curl -sS -m 8 -I -o /dev/null "$URL" 2>/dev/null; then
    echo "[orenovpn] ✅ 外部から到達OK / 信頼された証明書。iPhone で QR をスキャンすれば警告なしで導入できます。"
  else
    echo "[orenovpn] ✅ 外部から到達OK（証明書は自己署名）。iPhone では警告→手動承認で進めてください。"
  fi
else
  echo "[orenovpn] ⚠️ 外部から到達できません（code=${code}）。この出力を貼ってください。"
fi
echo
echo "有効 ${DURATION} 秒 / ダウンロード ${MAXDL} 回まで。取得後は Ctrl-C で即停止できます。"
echo "配信中に来た要求（拒否も含む）は サーバーの /var/log/orenovpn-serve.log に残ります:"
echo "  make ssh → sudo tail -n 50 /var/log/orenovpn-serve.log"
sleep "${DURATION}"
