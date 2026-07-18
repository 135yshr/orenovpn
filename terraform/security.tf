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
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.vpn.id
  description       = "SSH"
}

locals {
  is_wireguard = var.vpn_protocol == "wireguard"
  is_ikev2     = var.vpn_protocol == "ikev2"
  # IKEv2/IPsec は IKE(500/udp) と NAT-T(4500/udp) を使用
  ikev2_ports = [500, 4500]
}

# --- WireGuard（UDP / 全世界）-----------------------------------------------
resource "openstack_networking_secgroup_rule_v2" "wireguard_v4" {
  count             = local.is_wireguard ? 1 : 0
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
  count             = local.is_wireguard && var.wg_enable_ipv6 ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "udp"
  port_range_min    = var.wg_port
  port_range_max    = var.wg_port
  remote_ip_prefix  = "::/0"
  security_group_id = openstack_networking_secgroup_v2.vpn.id
  description       = "WireGuard IPv6"
}

# --- IKEv2/IPsec（UDP 500 / 4500 全世界）-----------------------------------
resource "openstack_networking_secgroup_rule_v2" "ikev2_v4" {
  for_each          = local.is_ikev2 ? toset([for p in local.ikev2_ports : tostring(p)]) : toset([])
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = tonumber(each.value)
  port_range_max    = tonumber(each.value)
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.vpn.id
  description       = "IKEv2 IPv4 ${each.value}"
}

resource "openstack_networking_secgroup_rule_v2" "ikev2_v6" {
  for_each          = local.is_ikev2 && var.wg_enable_ipv6 ? toset([for p in local.ikev2_ports : tostring(p)]) : toset([])
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "udp"
  port_range_min    = tonumber(each.value)
  port_range_max    = tonumber(each.value)
  remote_ip_prefix  = "::/0"
  security_group_id = openstack_networking_secgroup_v2.vpn.id
  description       = "IKEv2 IPv6 ${each.value}"
}

# 配信ポート(80/443)は ConoHa 定義済み SG "IPv4v6-Web" をインスタンスに
# アタッチして開ける（main.tf 参照）。カスタム SG の 443 ルールは ConoHa が
# 適用しないため、ここには置かない。

# --- ICMP（疎通確認用）------------------------------------------------------
resource "openstack_networking_secgroup_rule_v2" "icmp_v4" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "icmp"
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.vpn.id
  description       = "ICMP"
}
