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
    # 配信ポートを apply 時にランダム決定するために使用（randomize_profile_port）。
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
