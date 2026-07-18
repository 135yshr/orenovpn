# ConoHa VPS Ver.3.0（OpenStack 準拠）への接続設定
#
# 認証情報は ConoHa コントロールパネルの「API」メニューから取得する。
#   - auth_url    : https://identity.c3j1.conoha.io/v3
#   - tenant_name : gnct******** で始まる値
#   - user_name   : gncu******** で始まる値
#   - password    : API ユーザー作成時に設定したパスワード
#   - domain_name : "gnc" 固定
#
# セキュリティのため、認証情報は terraform.tfvars に直接書かず
# 環境変数（OS_*）で渡すことも可能。README を参照。
provider "openstack" {
  auth_url    = var.conoha_auth_url
  domain_name = var.conoha_domain_name
  tenant_name = var.conoha_tenant_name
  user_name   = var.conoha_user_name
  password    = var.conoha_password
}
