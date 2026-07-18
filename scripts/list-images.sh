#!/usr/bin/env bash
#
# list-images.sh : ConoHa VPS v3 で現在利用可能な OS イメージ一覧を取得する
#
#   terraform.tfvars（または OS_* 環境変数）の認証情報を使って ConoHa の
#   Image API を叩き、`image_name` に指定できるイメージ名を一覧表示する。
#
#   使い方:
#     ./scripts/list-images.sh              # 全 OS イメージ
#     ./scripts/list-images.sh debian       # 名前で絞り込み（例: debian）
#     make images                           # 同等（Makefile 経由）
#
#   必要なもの: curl, python3（追加の CLI インストールは不要）
#
set -euo pipefail

FILTER="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="${SCRIPT_DIR}/../terraform/terraform.tfvars"

die() { echo "エラー: $*" >&2; exit 1; }
command -v curl >/dev/null    || die "curl が必要です"
command -v python3 >/dev/null || die "python3 が必要です"

# terraform.tfvars から key = "value" 形式の値を取り出す
getvar() {
  [ -f "$TFVARS" ] || return 0
  # キーが無い場合 grep が非ゼロ終了して set -e で落ちるのを防ぐため || true
  { grep -E "^[[:space:]]*$1[[:space:]]*=" "$TFVARS" 2>/dev/null | head -1 \
    | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*[^"# ])"?.*$/\1/'; } || true
}

# 認証情報: OS_* 環境変数を優先し、無ければ terraform.tfvars から取得
AUTH_URL="${OS_AUTH_URL:-$(getvar conoha_auth_url)}"
AUTH_URL="${AUTH_URL:-https://identity.c3j1.conoha.io/v3}"
DOMAIN="${OS_USER_DOMAIN_NAME:-$(getvar conoha_domain_name)}"
DOMAIN="${DOMAIN:-gnc}"
TENANT="${OS_TENANT_NAME:-$(getvar conoha_tenant_name)}"
USERNAME="${OS_USERNAME:-$(getvar conoha_user_name)}"
PASSWORD="${OS_PASSWORD:-$(getvar conoha_password)}"

[ -n "$TENANT" ] && [ -n "$USERNAME" ] && [ -n "$PASSWORD" ] \
  || die "認証情報が見つかりません。terraform/terraform.tfvars を設定するか OS_* 環境変数を指定してください。"

hdrs="$(mktemp)"; body="$(mktemp)"
trap 'rm -f "$hdrs" "$body"' EXIT

# 1) Keystone でトークンとサービスカタログを取得
payload=$(python3 - "$USERNAME" "$DOMAIN" "$PASSWORD" "$TENANT" <<'PY'
import json, sys
u, d, p, t = sys.argv[1:5]
print(json.dumps({"auth": {
  "identity": {"methods": ["password"],
    "password": {"user": {"name": u, "domain": {"name": d}, "password": p}}},
  "scope": {"project": {"name": t, "domain": {"name": d}}}}}))
PY
)

curl -sS -X POST "${AUTH_URL%/}/auth/tokens" \
  -H "Content-Type: application/json" -d "$payload" \
  -D "$hdrs" -o "$body" || die "認証リクエストに失敗しました"

TOKEN="$(awk 'tolower($1)=="x-subject-token:"{print $2}' "$hdrs" | tr -d '\r\n')"
[ -n "$TOKEN" ] || die "認証に失敗しました（認証情報を確認してください）。応答: $(head -c 300 "$body")"

# サービスカタログから Image サービスの公開エンドポイントを取得
IMG_EP="$(python3 - "$body" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for s in d.get("token", {}).get("catalog", []):
    if s.get("type") == "image":
        pub = [e["url"] for e in s.get("endpoints", []) if e.get("interface") == "public"]
        if pub:
            print(pub[0].rstrip("/")); break
PY
)"
[ -n "$IMG_EP" ] || die "Image サービスのエンドポイントが見つかりませんでした"

# 2) イメージ一覧を取得
case "$IMG_EP" in
  */v2) LIST_URL="${IMG_EP}/images" ;;
  *)    LIST_URL="${IMG_EP}/v2/images" ;;
esac
curl -sS "${LIST_URL}?limit=1000" -H "X-Auth-Token: $TOKEN" -o "$body" \
  || die "イメージ一覧の取得に失敗しました"

# 3) 整形して表示（vmi- で始まる OS イメージを名前順に）
python3 - "$body" "$FILTER" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
flt = (sys.argv[2] or "").lower()
imgs = d.get("images", [])
names = sorted({i["name"] for i in imgs if i.get("name", "").startswith("vmi-")})
if flt:
    names = [n for n in names if flt in n.lower()]
if not names:
    print("該当するイメージが見つかりませんでした。"); sys.exit(0)
print("=== image_name に指定できる OS イメージ ===")
for n in names:
    print(f"  {n}")
print()
print(f"合計 {len(names)} 件。terraform.tfvars の image_name に上記の文字列をそのまま設定します。")
PY
