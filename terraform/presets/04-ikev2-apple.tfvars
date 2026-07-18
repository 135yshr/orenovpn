# =============================================================================
# プリセット ④ IKEv2（iPhone / macOS 標準VPN・アプリ不要）
# -----------------------------------------------------------------------------
# 方針: Apple 端末の標準VPNでそのまま接続できることを最優先。
#       - vpn_protocol = "ikev2"（証明書認証・.mobileconfig ワンタップ導入）
#       - SSH ポートは独自値に変更、fail2ban / 自動更新は明示 ON
#       - 初期クライアントは iPhone と Mac
# 向いている人: iPhone/iPad/Mac で追加アプリを入れずに使いたい
#
# 構成は terraform.tfvars.example と同じ①〜⑥。有効な行がこのプリセットの設定、
# 「#」付きは既定値。変えたい項目は # を外して編集する。
# =============================================================================

# --- ① ConoHa API 認証情報（必須）------------------------------------------
conoha_tenant_name = "gnct00000000"
conoha_user_name   = "gncu00000000"
conoha_password    = "CHANGE_ME"

# --- ② SSH 公開鍵（必須）----------------------------------------------------
ssh_public_key = "ssh-ed25519 AAAAC3Nza... CHANGE_ME"

# --- ③ サーバー構成 ---------------------------------------------------------
# instance_name = "orenovpn"              # ConoHa 上の表示名
# flavor_name   = "g2l-t-c1m512"          # プラン（最安 512MB）
image_name = "vmi-debian-13.5-amd64" # OS(Debian13)。make images で確認。Debian/Ubuntu系のみ
# volume_size   = 30                      # GB。512MBプランは30固定/上位プランは100等
# timezone      = "Asia/Tokyo"

# VPN 方式: iPhone/macOS 標準VPNでアプリ不要接続（.mobileconfig ワンタップ）
vpn_protocol = "ikev2"

# --- ④ SSH アクセス制御（SSHは22番固定）------------------------------------
# admin_user       = "vpnadmin"           # 管理ユーザー名

# 固定IPに絞ると安全（curl -4 ifconfig.co で確認）。IP可変環境は既定の全開放のまま。
# allowed_ssh_cidr = ["203.0.113.10/32"]

# --- ⑤ VPN（IKEv2 で使う項目）----------------------------------------------
# wg_dns はクライアントに配布する DNS として IKEv2 でも使われる:
# wg_dns         = "1.1.1.1,1.0.0.1"      # 例: Quad9 "9.9.9.9,149.112.112.112"
# wg_enable_ipv6 = true                   # IKEv2 の IPv6 用SGルールを開けるか
# 接続する端末（Apple 端末を想定。1端末=1プロファイル）:
wg_clients = ["iphone", "mac"] # 例: 追加で "ipad" など
# ※ wg_port / wg_allowed_ips は WireGuard 専用のため IKEv2 では未使用。

# --- ⑥ セキュリティ強化 -----------------------------------------------------
enable_fail2ban     = true # SSH ブルートフォース対策
enable_auto_updates = true # 自動セキュリティ更新
