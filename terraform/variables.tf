# =============================================================================
# 変数定義
# 実際の値は terraform.tfvars で設定する（terraform.tfvars.example をコピー）。
# ほとんどの変数にデフォルト値があり、最小構成なら認証情報と SSH 公開鍵だけで動く。
# =============================================================================

# -----------------------------------------------------------------------------
# ConoHa 認証情報（必須）
# -----------------------------------------------------------------------------
variable "conoha_auth_url" {
  description = "ConoHa v3 Identity(Keystone) エンドポイント"
  type        = string
  default     = "https://identity.c3j1.conoha.io/v3"
}

variable "conoha_domain_name" {
  description = "ConoHa のドメイン名（固定値）"
  type        = string
  default     = "gnc"
}

variable "conoha_tenant_name" {
  description = "テナント名（gnct******** で始まる値）"
  type        = string
}

variable "conoha_user_name" {
  description = "API ユーザー名（gncu******** で始まる値）"
  type        = string
}

variable "conoha_password" {
  description = "API ユーザーのパスワード"
  type        = string
  sensitive   = true
}

# -----------------------------------------------------------------------------
# サーバー構成
# -----------------------------------------------------------------------------
variable "instance_name" {
  description = "作成する VPS の名前（ネームタグ）"
  type        = string
  default     = "orenovpn"
}

variable "flavor_name" {
  description = <<-EOT
    サーバープラン（flavor）名。時間課金 Linux プランの例:
      g2l-t-c1m512 (512MB/1vCPU) … 最安・VPN 用途に十分
      g2l-t-c2m1   (1GB/2vCPU)
    `openstack flavor list` で確認できる。
  EOT
  type        = string
  default     = "g2l-t-c1m512"
}

variable "image_name" {
  description = <<-EOT
    OS イメージ名（データソースは完全一致で検索する）。
    提供バージョンは時期で変わるため `make images`（scripts/list-images.sh）で
    現在利用できる正確な名称を確認すること。
    例: vmi-debian-13.5-amd64 / vmi-debian-12.5-amd64 / vmi-ubuntu-24.04-amd64
    cloud-init + apt 前提のため Debian / Ubuntu 系のみ対応（RHEL系は不可）。
  EOT
  type        = string
  default     = "vmi-debian-13.5-amd64"
}

variable "volume_size" {
  description = <<-EOT
    ブートボリュームサイズ(GB)。プランごとに許容サイズが決まっている。
    512MB プラン(g2l-t-c1m512) は 30GB 固定。上位プランは 100GB など。
    プランを変えたらこの値も合わせること。
  EOT
  type        = number
  default     = 30
}

variable "volume_type" {
  description = <<-EOT
    ブロックストレージのボリュームタイプ名。ブート用は末尾が -boot のもの。
    利用可能な値は `make volume-types` で確認できる（例: c3j1-ds02-boot）。
  EOT
  type        = string
  default     = "c3j1-ds02-boot"
}

# -----------------------------------------------------------------------------
# SSH アクセス
# -----------------------------------------------------------------------------
variable "admin_user" {
  description = "作成する管理用 sudo ユーザー名"
  type        = string
  default     = "vpnadmin"
}

variable "ssh_public_key" {
  description = "管理ユーザーに登録する SSH 公開鍵（ssh-ed25519 ... 形式の文字列）"
  type        = string
}

variable "ssh_port" {
  description = "SSH の待ち受けポート。既定の 22 から変更してスキャンを回避。"
  type        = number
  default     = 22022
}

variable "allowed_ssh_cidr" {
  description = <<-EOT
    SSH 接続を許可する送信元 CIDR のリスト。
    自宅/オフィスの固定 IP に絞ると安全性が大きく向上する。
    例: ["203.0.113.10/32"]。不明な場合は ["0.0.0.0/0"]（非推奨）。
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# -----------------------------------------------------------------------------
# WireGuard 設定
# -----------------------------------------------------------------------------
variable "wg_port" {
  description = "WireGuard の待ち受け UDP ポート"
  type        = number
  default     = 51820
}

variable "wg_address_v4" {
  description = "サーバーの VPN 内 IPv4 アドレス"
  type        = string
  default     = "10.66.66.1"
}

variable "wg_subnet_v4" {
  description = "VPN の IPv4 サブネット"
  type        = string
  default     = "10.66.66.0/24"
}

variable "wg_enable_ipv6" {
  description = "VPN 内で IPv6 も有効にするか"
  type        = bool
  default     = true
}

variable "wg_address_v6" {
  description = "サーバーの VPN 内 IPv6 アドレス（ULA）"
  type        = string
  default     = "fd42:66:66::1"
}

variable "wg_subnet_v6" {
  description = "VPN の IPv6 サブネット（ULA）"
  type        = string
  default     = "fd42:66:66::/64"
}

variable "wg_dns" {
  description = "クライアントに配布する DNS サーバー（カンマ区切り）"
  type        = string
  default     = "1.1.1.1,1.0.0.1"
}

variable "wg_allowed_ips" {
  description = <<-EOT
    クライアント設定の AllowedIPs。
    "0.0.0.0/0,::/0" で全トラフィックを VPN 経由（フルトンネル）。
  EOT
  type        = string
  default     = "0.0.0.0/0,::/0"
}

variable "wg_clients" {
  description = <<-EOT
    初期作成するクライアント名のリスト。
    apply 後、各クライアントの設定と QR コードがサーバー上に生成される。
    例: ["phone", "laptop"]
  EOT
  type        = list(string)
  default     = ["client1"]
}

# -----------------------------------------------------------------------------
# セキュリティ強化オプション
# -----------------------------------------------------------------------------
variable "enable_fail2ban" {
  description = "fail2ban（SSH ブルートフォース対策）を有効化"
  type        = bool
  default     = true
}

variable "enable_auto_updates" {
  description = "unattended-upgrades（自動セキュリティ更新）を有効化"
  type        = bool
  default     = true
}

variable "timezone" {
  description = "サーバーのタイムゾーン"
  type        = string
  default     = "Asia/Tokyo"
}
