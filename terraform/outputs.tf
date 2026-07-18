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
    │  VPS を作成しました。cloud-init による初期設定が数分続きます。   │
    └────────────────────────────────────────────────────────────────┘

    1) 初期設定の完了を待つ（初回のみ 3〜5 分程度）:
         ssh -p ${var.ssh_port} ${var.admin_user}@${openstack_compute_instance_v2.this.access_ip_v4} \
           'cloud-init status --wait'

    2) 初期クライアントの設定/QR コードを取得:
         ssh -p ${var.ssh_port} ${var.admin_user}@${openstack_compute_instance_v2.this.access_ip_v4} \
           'sudo wg-client show ${length(var.wg_clients) > 0 ? var.wg_clients[0] : "client1"}'

    3) クライアントを追加:
         ssh -p ${var.ssh_port} ${var.admin_user}@${openstack_compute_instance_v2.this.access_ip_v4} \
           'sudo wg-client add my-phone'

    Makefile を使う場合は `make status` / `make client NAME=my-phone` が便利です。
  EOT
}
