# =============================================================================
# メインリソース定義
#   1. OS イメージ / flavor の参照
#   2. SSH キーペア登録
#   3. ブートボリューム作成
#   4. VPS インスタンス作成（cloud-init で WireGuard を自動構成）
# =============================================================================

# --- OS イメージの参照 -------------------------------------------------------
data "openstack_images_image_v2" "os" {
  name        = var.image_name
  most_recent = true
}

# --- flavor(プラン) の参照 ---------------------------------------------------
data "openstack_compute_flavor_v2" "plan" {
  name = var.flavor_name
}

# --- SSH キーペア ------------------------------------------------------------
resource "openstack_compute_keypair_v2" "this" {
  name       = "${var.instance_name}-key"
  public_key = var.ssh_public_key
}

# --- ブートボリューム（イメージから作成）------------------------------------
resource "openstack_blockstorage_volume_v3" "boot" {
  name        = "${var.instance_name}-boot"
  size        = var.volume_size
  image_id    = data.openstack_images_image_v2.os.id
  volume_type = var.volume_type

  # ボリュームは OS を含むため、誤削除防止のライフサイクル制御が必要な場合は
  # ここに prevent_destroy を追加する。
}

# --- cloud-init（フェーズ1・最小構成）--------------------------------------
# スクリプトは埋め込まず、フェーズ2（make setup）で SSH 転送・実行する。
# これにより user_data は小さく保たれ、初回ブートも高速・確実になる。
locals {
  cloud_init = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    admin_user             = var.admin_user
    ssh_public_key         = var.ssh_public_key
    timezone               = var.timezone
    wg_port                = var.wg_port
    wg_address_v4          = var.wg_address_v4
    wg_subnet_v4           = var.wg_subnet_v4
    wg_enable_ipv6         = var.wg_enable_ipv6
    wg_address_v6          = var.wg_address_v6
    wg_subnet_v6           = var.wg_subnet_v6
    wg_dns                 = var.wg_dns
    wg_allowed_ips         = var.wg_allowed_ips
    wg_clients             = var.wg_clients
    enable_fail2ban        = var.enable_fail2ban
    enable_auto_updates    = var.enable_auto_updates
    vpn_protocol           = var.vpn_protocol
    enable_cert_revocation = var.enable_cert_revocation
  })
}

# --- VPS インスタンス --------------------------------------------------------
resource "openstack_compute_instance_v2" "this" {
  name      = var.instance_name
  flavor_id = data.openstack_compute_flavor_v2.plan.id
  key_pair  = openstack_compute_keypair_v2.this.name

  # カスタム SG（VPN 用）に加え、配信用に ConoHa 定義済み SG "IPv4v6-Web"(80/443) を
  # アタッチする（enable_profile_download 時のみ）。Let's Encrypt の HTTP-01 が使う
  # ポート80 を確実に開けるのが主目的。任意ポート配信はカスタム SG ルール
  # (security.tf の profile_v4/v6) で開く（nftables 無効化後は TCP も正常に機能する）。
  security_groups = var.enable_profile_download ? [
    openstack_networking_secgroup_v2.vpn.name, "IPv4v6-Web"
  ] : [openstack_networking_secgroup_v2.vpn.name]

  # 全 SG ルールの作成完了後にインスタンスを作る（作成時点の SG を確実に反映させる）。
  depends_on = [
    openstack_networking_secgroup_rule_v2.ssh,
    openstack_networking_secgroup_rule_v2.wireguard_v4,
    openstack_networking_secgroup_rule_v2.wireguard_v6,
    openstack_networking_secgroup_rule_v2.ikev2_v4,
    openstack_networking_secgroup_rule_v2.ikev2_v6,
    openstack_networking_secgroup_rule_v2.icmp_v4,
    openstack_networking_secgroup_rule_v2.profile_v4,
    openstack_networking_secgroup_rule_v2.profile_v6,
  ]

  user_data = local.cloud_init

  # user_data を config-drive 経由で確実に配信する。
  # ConoHa では metadata サービス経由の user_data が cloud-init に適用されない
  # ことがあり、config-drive にすると #cloud-config が確実に処理される。
  config_drive = true

  # ネームタグ（ConoHa コントロールパネルでの表示名）
  metadata = {
    instance_name_tag = var.instance_name
  }

  # ブートボリュームからの起動
  block_device {
    uuid                  = openstack_blockstorage_volume_v3.boot.id
    source_type           = "volume"
    destination_type      = "volume"
    boot_index            = 0
    delete_on_termination = false
  }

  # user_data / セキュリティグループの変更で再作成が走らないよう抑制。
  # 構成変更はサーバー上のスクリプトで行う運用とする。
  lifecycle {
    ignore_changes = [user_data]
  }
}
