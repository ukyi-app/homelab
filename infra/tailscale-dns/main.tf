locals {
  # 첫 import와 무변경 plan 확인 뒤 별도 PR에서 target으로 바꾼다. 환경변수로 건너뛰지 않는다.
  dns_phase = "adopt"
}

data "tailscale_devices" "nuc" {
  filter {
    name   = "hostname"
    values = ["nuc-15-pro"]
  }
}

locals {
  nuc_devices = [for device in data.tailscale_devices.nuc.devices : device if device.hostname == "nuc-15-pro"]
  # 인덱스 오류가 precondition의 원인 설명을 가리지 않도록 기본값으로 평가를 계속한다.
  nuc = try(local.nuc_devices[0], null)
  nuc_ipv4 = try([
    for address in local.nuc.addresses : address
    if startswith(address, "100.") && can(cidrnetmask("${address}/32"))
  ], [])
  desired_dns = {
    override_local_dns = true
    magic_dns          = true
    nameservers = [
      { address = try(local.nuc_ipv4[0], ""), use_with_exit_node = false },
      { address = "94.140.14.14", use_with_exit_node = false },
      { address = "94.140.15.15", use_with_exit_node = false }
    ]
    # D-08이 바꾸지 않는 사용자 split DNS와 검색 도메인은 첫 사본에서 보존한다.
    split_dns    = var.dns_adoption_snapshot.split_dns
    search_paths = var.dns_adoption_snapshot.search_paths
  }
  dns = local.dns_phase == "adopt" ? var.dns_adoption_snapshot : local.desired_dns
}

# DNS 전체를 소유하므로 처음부터 import한다. ID는 provider에서 의미 없는 임의 문자열이다.
import {
  to = tailscale_dns_configuration.homelab
  id = "dns_configuration"
}

resource "tailscale_dns_configuration" "homelab" {
  override_local_dns = local.dns.override_local_dns
  magic_dns          = local.dns.magic_dns
  search_paths       = local.dns.search_paths

  dynamic "nameservers" {
    for_each = local.dns.nameservers
    content {
      address            = nameservers.value.address
      use_with_exit_node = nameservers.value.use_with_exit_node
    }
  }

  dynamic "split_dns" {
    for_each = local.dns.split_dns
    content {
      domain = split_dns.value.domain
      dynamic "nameservers" {
        for_each = split_dns.value.nameservers
        content {
          address            = nameservers.value.address
          use_with_exit_node = nameservers.value.use_with_exit_node
        }
      }
    }
  }

  lifecycle {
    # count로 NUC 부재를 표현하면 DNS 설정 전체를 지우는 계획이 나온다. 복구 중에는 이 root를 apply하지 않는다.
    prevent_destroy = true

    precondition {
      condition     = contains(["adopt", "target"], local.dns_phase)
      error_message = "dns_phase는 adopt 또는 target만 허용한다."
    }
    precondition {
      condition     = length(local.nuc_devices) == 1
      error_message = "hostname nuc-15-pro는 정확히 1대여야 한다. DNS 적용을 중단한다."
    }
    precondition {
      condition     = try(local.nuc.user == var.nuc_expected_owner && length(local.nuc.tags) == 0, false)
      error_message = "NUC는 기대 소유자의 태그 없는 기기여야 한다."
    }
    precondition {
      condition     = try(local.nuc.key_expiry_disabled == true, false)
      error_message = "콘솔에서 NUC 키 만료를 해제한 뒤 실행한다."
    }
    precondition {
      condition     = length(local.nuc_ipv4) == 1
      error_message = "NUC에는 100.으로 시작하는 IPv4가 정확히 1개 필요하다."
    }
  }
}
