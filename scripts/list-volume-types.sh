#!/usr/bin/env bash
#
# list-volume-types.sh : ConoHa VPS v3 で利用可能なボリュームタイプ一覧を取得する
#
#   terraform.tfvars（または OS_* 環境変数）の認証情報を使って
#   Block Storage(Cinder) API を叩き、volume_type に指定できる名前を表示する。
#
#   使い方:  ./scripts/list-volume-types.sh   /   make volume-types
#   必要なもの: curl, python3
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="${SCRIPT_DIR}/../terraform/terraform.tfvars"

die() { echo "エラー: $*" >&2; exit 1; }
command -v curl >/dev/null    || die "curl が必要です"
command -v python3 >/dev/null || die "python3 が必要です"

getvar() {
  [ -f "$TFVARS" ] || return 0
  # キーが無い場合 grep が非ゼロ終了して set -e で落ちるのを防ぐため || true
  { grep -E "^[[:space:]]*$1[[:space:]]*=" "$TFVARS" 2>/dev/null | head -1 \
    | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*[^"# ])"?.*$/\1/'; } || true
}

AUTH_URL="${OS_AUTH_URL:-$(getvar conoha_auth_url)}"
AUTH_URL="${AUTH_URL:-https://identity.c3j1.conoha.io/v3}"
DOMAIN="${OS_USER_DOMAIN_NAME:-$(getvar conoha_domain_name)}"
DOMAIN="${DOMAIN:-gnc}"
TENANT="${OS_TENANT_NAME:-$(getvar conoha_tenant_name)}"
USERNAME="${OS_USERNAME:-$(getvar conoha_user_name)}"
PASSWORD="${OS_PASSWORD:-$(getvar conoha_password)}"

[ -n "$TENANT" ] && [ -n "$USERNAME" ] && [ -n "$PASSWORD" ] \
  || die "認証情報が見つかりません。terraform/terraform.tfvars か OS_* 環境変数を設定してください。"

hdrs="$(mktemp)"; body="$(mktemp)"
trap 'rm -f "$hdrs" "$body"' EXIT

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

# サービスカタログから Block Storage の公開エンドポイントを取得
EP="$(python3 - "$body" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
want = ("volumev3", "block-storage", "volume", "volumev2")
best = None
for s in d.get("token", {}).get("catalog", []):
    if s.get("type") in want:
        for e in s.get("endpoints", []):
            if e.get("interface") == "public":
                best = e["url"].rstrip("/")
                if s.get("type") == "volumev3":
                    print(best); sys.exit(0)
if best:
    print(best)
PY
)"
[ -n "$EP" ] || die "Block Storage サービスのエンドポイントが見つかりませんでした"

curl -sS "${EP}/types" -H "X-Auth-Token: $TOKEN" -o "$body" \
  || die "ボリュームタイプ一覧の取得に失敗しました"

python3 - "$body" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
types = d.get("volume_types", [])
if not types:
    print("ボリュームタイプが取得できませんでした。応答:", json.dumps(d)[:300]); sys.exit(0)
print("=== volume_type に指定できる値 ===")
for t in types:
    name = t.get("name", "?")
    desc = (t.get("description") or "").strip()
    print(f"  {name}" + (f"   ({desc})" if desc else ""))
print()
print("terraform.tfvars の volume_type に上記いずれかを設定します。")
PY
