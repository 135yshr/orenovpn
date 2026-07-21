# =============================================================================
# プリセット ① 簡単・すぐ使える
# -----------------------------------------------------------------------------
# 方針: 最短で動かす。編集は【① 認証情報＋② SSH公開鍵】だけでOK。
#       鍵認証のみ・fail2ban・自動更新は既定でON。SSHはどこからでも接続可。
# 向いている人: まず試したい / 接続元IPが変わる（外出先・モバイル回線）
#
# 構成は terraform.tfvars.example と同じ①〜⑥。有効な行がこのプリセットの設定、
# 「#」付きは既定値。変えたい項目は # を外して編集する。
# =============================================================================

# --- ① ConoHa API 認証情報（必須）------------------------------------------
# コントロールパネル → API メニューから取得
conoha_tenant_name = "gnct00000000"
conoha_user_name   = "gncu00000000"
conoha_password    = "CHANGE_ME"

# --- ② SSH 公開鍵（必須）----------------------------------------------------
# ssh-keygen で作った .pub の中身を貼り付け
ssh_public_key = "ssh-ed25519 AAAAC3Nza... CHANGE_ME"

# --- ③ サーバー構成 ---------------------------------------------------------
# instance_name = "orenovpn"              # ConoHa 上の表示名
# flavor_name   = "g2l-t-c1m512"          # プラン（最安 512MB）
image_name = "vmi-debian-13.5-amd64" # OS(Debian13)。make images で確認。Debian/Ubuntu系のみ
# volume_size   = 30                      # GB。512MBプランは30固定/上位プランは100等
# timezone      = "Asia/Tokyo"

# VPN 方式: "wireguard"(専用アプリ) / "ikev2"(iPhone/macOS標準VPN・アプリ不要)
vpn_protocol = "wireguard"

# --- ④ SSH アクセス制御（SSHは22番固定）------------------------------------
# admin_user       = "vpnadmin"           # 管理ユーザー名
# allowed_ssh_cidr = ["0.0.0.0/0"]        # 固定IPに絞ると安全: ["203.0.113.10/32"]

# --- ⑤ WireGuard ------------------------------------------------------------
# wg_port        = 51820                  # WireGuard の UDP ポート
# wg_dns         = "1.1.1.1,1.0.0.1"      # 例: プライバシー重視なら Quad9 "9.9.9.9"
# wg_enable_ipv6 = true                   # VPN 内 IPv6
# wg_allowed_ips = "0.0.0.0/0,::/0"       # フルトンネル（全通信を VPN 経由）
# 接続する端末。パソコンも使うなら "laptop" などを追加:
wg_clients = ["phone"] # 例: ["phone", "laptop", "tablet"]

# --- ⑥ セキュリティ強化（既定で ON）----------------------------------------
# enable_fail2ban     = true              # SSH ブルートフォース対策
# enable_auto_updates = true              # 自動セキュリティ更新
# --- QR配布/失効の詳細（任意）---
# randomize_profile_port = true           # make serve-profile の配信ポートをランダム化
# enable_cert_revocation = true           # IKEv2証明書の失効(CRL)を有効化（make remove で失効可能）

# 通信監視・警告を使うなら（詳細は docs/ALERTING.md）:
#   注意: smtp_password を tfvars に書くと Terraform state に平文で残ります。
#   state に残したくない場合は tfvars で設定せず `make configure-alerts` を使ってください。
# enable_traffic_alert = true
# alert_email          = "you@example.com"
# smtp_host            = "smtp.gmail.com"
# smtp_user            = "you@example.com"
# smtp_password        = "CHANGE_ME_APP_PASSWORD" # ← state に平文保存。configure-alerts 推奨
