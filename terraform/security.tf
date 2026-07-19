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

  # 実効配信ポート: randomize_profile_port なら apply 時のランダム値、そうでなければ指定値。
  profile_port = var.randomize_profile_port ? random_integer.profile_port[0].result : var.profile_port
  # 80/443 は IPv4v6-Web が開くのでカスタムルール不要。それ以外はカスタムルールで開く。
  # count は plan 時に確定する必要があるため、apply 時確定の local.profile_port ではなく
  # plan 時確定の変数（randomize フラグ or 指定ポート）で判定する。
  need_profile_rule = var.enable_profile_download && (var.randomize_profile_port || (var.profile_port != 443 && var.profile_port != 80))
}

# 配信ポートを apply 時にランダム決定（デプロイ単位で固定、state に保持される）。
resource "random_integer" "profile_port" {
  count = var.randomize_profile_port ? 1 : 0
  min   = 20000
  max   = 60000
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

# 配信ポート: 80/443 は ConoHa 定義済み SG "IPv4v6-Web" をアタッチして開ける（main.tf 参照）。
# それ以外（ランダム/任意の TCP ポート）はカスタム SG ルールで開く。UDP のカスタムルール
# （WireGuard/IKEv2）は実績があるため、TCP も nftables 無効化後は同様に機能する想定。
# LE 証明書取得（HTTP-01/80）は IPv4v6-Web が担保する。
resource "openstack_networking_secgroup_rule_v2" "profile_v4" {
  count             = local.need_profile_rule ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = local.profile_port
  port_range_max    = local.profile_port
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.vpn.id
  description       = "orenovpn profile download IPv4"
}

resource "openstack_networking_secgroup_rule_v2" "profile_v6" {
  count             = local.need_profile_rule ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = local.profile_port
  port_range_max    = local.profile_port
  remote_ip_prefix  = "::/0"
  security_group_id = openstack_networking_secgroup_v2.vpn.id
  description       = "orenovpn profile download IPv6"
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
