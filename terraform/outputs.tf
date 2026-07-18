# =============================================================================
# 出力（apply 後に表示される接続情報）
# =============================================================================

output "server_ip" {
  description = "VPS のパブリック IPv4 アドレス"
  value       = openstack_compute_instance_v2.this.access_ip_v4
}

output "ssh_command" {
  description = "サーバーへ SSH 接続するコマンド"
  value       = "ssh -p ${var.ssh_port} ${var.admin_user}@${openstack_compute_instance_v2.this.access_ip_v4}"
}

output "ssh_port" {
  description = "SSH ポート番号"
  value       = var.ssh_port
}

output "admin_user" {
  description = "SSH 管理ユーザー名"
  value       = var.admin_user
}

output "wireguard_endpoint" {
  description = "WireGuard クライアントが接続するエンドポイント"
  value       = "${openstack_compute_instance_v2.this.access_ip_v4}:${var.wg_port}"
}

output "next_steps" {
  description = "セットアップ完了までの案内"
  value       = <<-EOT

    ┌────────────────────────────────────────────────────────────────┐
    │  VPS を作成しました（フェーズ1）。次に構成を実行してください。   │
    └────────────────────────────────────────────────────────────────┘

    1) SSH 疎通を確認（初回ブートは 1〜2 分程度）:
         make status

    2) ソフト導入・VPN 構成を実行（画面で進捗を確認）:
         make setup

    3) クライアントの QR コードを表示:
         make show NAME=${length(var.wg_clients) > 0 ? var.wg_clients[0] : "phone"}

    ※ SSH 鍵が既定パス以外なら各コマンドに SSH_KEY=... を付けてください。
       例: make status SSH_KEY=~/.ssh/orenovpn
  EOT
}
