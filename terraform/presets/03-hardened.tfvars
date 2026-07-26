# =============================================================================
# プリセット ③ できうる最高のセキュア設定
# -----------------------------------------------------------------------------
# 方針: 攻撃面を最小化し管理経路を厳格に絞る。
#       - SSH は高位ポート＋接続元を固定IPのみに厳格制限（必須）
#       - 管理ユーザー名を既定から変更  - WireGuard も非標準ポート
#       - DNS はプライバシー/セキュリティ重視の Quad9  - クライアント最小限
# 向いている人: セキュリティ最優先 / 固定IPから管理できることが前提
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

# VPN 方式: "wireguard"(専用アプリ) / "ikev2"(iPhone/macOS標準VPN・アプリ不要)
vpn_protocol = "wireguard"

# --- ④ SSH アクセス制御（厳格・SSHは22番固定）------------------------------
admin_user = "vpnops" # 既定名 vpnadmin を避け推測を回避

# 【必須】管理用の固定IPのみ許可。curl -4 ifconfig.co で確認して置換。
#   0.0.0.0/0 にすると本プリセットの意味が薄れる。
allowed_ssh_cidr = ["203.0.113.10/32"]

# --- ⑤ WireGuard ------------------------------------------------------------
wg_port = 51930                     # 非標準ポート
wg_dns  = "9.9.9.9,149.112.112.112" # Quad9（DNSSEC検証・悪性ドメインブロック）
# wg_enable_ipv6 = true                   # 不要なら false で攻撃面をさらに縮小
# wg_allowed_ips = "0.0.0.0/0,::/0"       # フルトンネル（全通信を VPN 経由）
# 接続する端末（最小限を推奨。パソコンも使うなら "laptop" を追加）:
wg_clients = ["phone"] # 例: ["phone", "laptop"]

# --- ⑥ セキュリティ強化 -----------------------------------------------------
enable_fail2ban     = true # SSH ブルートフォース対策
enable_auto_updates = true # 自動セキュリティ更新
# --- QR配布/失効の詳細（任意）---
# randomize_profile_port = true # make serve-profile の配信ポートをランダム化
# enable_cert_revocation = true # IKEv2証明書の失効(CRL)。既定 true のまま推奨（false は漏洩時に接続を止められない）

# --- ⑦ 通信監視・警告（怪しい通信をメール通知）------------------------------
# 詳細は docs/ALERTING.md。smtp_password は state / orenovpn.env に平文保存される点に注意。
enable_traffic_alert = true
alert_email          = "you@example.com"

# 送信方式は2択。どちらか一方だけを有効にする。
#  A) 外部 SMTP リレー（到達性が確実。smtp_password は state に平文で残るため
#     残したくない場合は空にして make configure-alerts で設定する）
smtp_host     = "smtp.gmail.com"
smtp_port     = 587
smtp_user     = "you@example.com"
smtp_password = "CHANGE_ME_APP_PASSWORD"
#  B) VPN 上のローカル MTA（外部 SMTP 不要・待受なし＝中継なし）
#     ★ 外向き25番・PTR・SPF の3点が揃わないと届きません（docs/ALERTING.md 参照）
# smtp_mode = "local"
# mail_from = "orenovpn@vpn.example.com" # 自分が管理するドメインのアドレス
# alert_ssh_fail_threshold = 20
# alert_traffic_mbytes     = 1024
# 出口通信検知（悪性IPへの通信をログ＆メール通知。ログのみ・遮断はしない）
# alert_blocklist_url = "https://example.com/malicious-ips.txt" # 1行1IP/CIDR

# --- ⑧ アクセス先の記録（不正利用の事後調査に必要な証跡）--------------------
# 「いつ・どの端末が・どこへ」を残す。URL は TLS 暗号化のため記録できない。
# 詳細と限界（SNI が将来課題である理由）は docs/ALERTING.md を参照。
enable_access_log = true # 宛先IP/ポートを記録（make access-log）
# ドメイン名も記録するならサーバー上に自前リゾルバ(unbound)を立てる。
# 端末が DoH/DoT を使うと迂回される点に注意。他人の端末も繋ぐ場合は周知してから有効化。
# enable_dns_logging = true # make dns-log で参照
# log_retention_days = 14   # 保存日数（journald 上限 1G）

# =============================================================================
# デプロイ後に追加で実施（docs/SECURITY.md 参照）:
#   □ クライアント側の kill switch を有効化（VPN切断時の漏洩防止）
#   □ auditd を導入してログイン/権限昇格を記録
#   □ クライアント秘密鍵を端末側で生成（サーバーを経由させない）
#   □ Terraform state を暗号化リモートバックエンドで管理
# =============================================================================
