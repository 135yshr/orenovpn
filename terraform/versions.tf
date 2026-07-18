# Terraform / プロバイダのバージョン制約
# ConoHa VPS Ver.3.0 は OpenStack 準拠 API を提供しているため、
# 公式の OpenStack プロバイダを利用する。
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 2.1"
    }
  }
}
