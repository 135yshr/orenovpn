# =============================================================================
# ネットワークセキュリティ（ConoHa/OpenStack セキュリティグループ）
#
# 方針: 最小許可（default deny）。
#   - SSH        : 指定 CIDR からのみ（既定は変更後ポート）
#   - WireGuard  : UDP を全世界から（VPN 接続に必須）
#   - ICMP       : 疎通確認用に許可（任意で無効化可）
#   - Egress     : OpenStack が既定で全許可ルールを自動付与
# サーバー内でも ufw / iptables で二重に防御する（cloud-init 参照）。
# =============================================================================

resource "openstack_networking_secgroup_v2" "vpn" {
  name        = "${var.instance_name}-sg"
  description = "orenovpn: allow SSH(limited), WireGuard(UDP), ICMP"
}

# --- SSH（送信元 CIDR を絞る）------------------------------------------------
resource "openstack_networking_secgroup_rule_v2" "ssh" {
  for_each          = toset(var.allowed_ssh_cidr)
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = var.ssh_port
  port_range_max    = var.ssh_port
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.vpn.id
  description       = "SSH"
}

# --- WireGuard（UDP / 全世界）-----------------------------------------------
resource "openstack_networking_secgroup_rule_v2" "wireguard_v4" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = var.wg_port
  port_range_max    = var.wg_port
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.vpn.id
  description       = "WireGuard IPv4"
}

resource "openstack_networking_secgroup_rule_v2" "wireguard_v6" {
  count             = var.wg_enable_ipv6 ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "udp"
  port_range_min    = var.wg_port
  port_range_max    = var.wg_port
  remote_ip_prefix  = "::/0"
  security_group_id = openstack_networking_secgroup_v2.vpn.id
  description       = "WireGuard IPv6"
}

# --- ICMP（疎通確認用）------------------------------------------------------
resource "openstack_networking_secgroup_rule_v2" "icmp_v4" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "icmp"
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.vpn.id
  description       = "ICMP"
}
