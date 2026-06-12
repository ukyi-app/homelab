locals {
  # 앱 레지스트리 SSOT — create-app/teardown 워크플로가 변이한다. 스키마:
  # [{ "name": "<app>", "host": "<fqdn>", "public": true, "active": false }]
  # active 게이트: 배포 revision이 Healthy로 확인된 뒤 activate-app이 true로 플립해야만
  # DNS/tunnel이 생성된다(배포 실패 중 외부 노출 0 — 등록과 공개의 분리).
  apps      = jsondecode(file("${path.module}/apps.json"))
  app_hosts = toset([for a in local.apps : a.host if a.public])

  tunnel_target = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  # apex/www는 코드 고정 유지, 앱 host는 데이터 합류
  public_hosts = toset(concat([var.zone_name, "www.${var.zone_name}"], tolist(local.app_hosts)))
}

resource "cloudflare_dns_record" "public" {
  for_each = local.public_hosts
  zone_id  = data.cloudflare_zone.this.zone_id
  name     = each.value
  type     = "CNAME"
  content  = local.tunnel_target
  proxied  = true
  ttl      = 1
}
